// LocalTokens - LM Studio server-log reader.
//
// LM Studio's server writes a llama.cpp timing block after every request (prompt
// tokens, generated tokens, times). This class reads those blocks from one or more
// server-logs folders on a background thread and keeps hourly totals per model.
// The first run reads every old log once; after that only what LM Studio appends.
//
// Written for the C# 5 compiler that Windows PowerShell 5.1's Add-Type uses:
// no string interpolation, no ?. or ?? on members, no expression-bodied members.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace LocalTokens {

public class Bucket {
    public long Req, Pp, Tg, Cached, Err;
    public double PpMs, TgMs;
}

public class ModelRow {
    public string Model;
    public long Req, Pp, Tg, Cached, Err;
    public double PpMs, TgMs;
    public long Tokens { get { return Pp + Tg; } }
    public double GenTps { get { return TgMs > 0 ? Tg / (TgMs / 1000.0) : 0; } }
    public double PromptTps { get { return PpMs > 0 ? Pp / (PpMs / 1000.0) : 0; } }
    public double CachePct { get { long all = Pp + Cached; return all > 0 ? 100.0 * Cached / all : 0; } }
}

public class LastRequest {
    public DateTime At;
    public string Model;
    public long Pp, Tg, Ctx;
    public double PpMs, TgMs;
}

public class SourceInfo {
    public string Name, Dir;
    public bool Exists;
    public DateTime LastSeen;      // newest log timestamp read from this folder
    public long Requests;
}

public class Snapshot {
    public bool CaughtUp, HasData;
    public double CatchUpPct;
    public string Error;
    public string ActiveSource;            // the folder whose server was active last
    public DateTime RunStart;              // that server's last start
    public DateTime SessionStart;          // start of what the session totals count
    public string SessionReason;           // "server", "load" or "switch"
    public string SessionModel;
    public ModelRow Session, Today, Week, AllTime;
    public DateTime FirstSeen;
    public List<ModelRow> SessionModels, TodayModels;
    public long[] Hourly = new long[24];   // tokens per hour, oldest first, last = current hour
    public string LiveKind;                // "prompt", "gen" or "idle"
    public string LiveModel;
    public double LiveTgTps, LiveProgress;
    public DateTime LastActivity;
    public long CtxSlot;
    public LastRequest Last;
    public List<SourceInfo> Sources;
}

public class Report {
    public string Period;                  // "24h", "today", "week", "month" or "year"
    public string Unit;                    // chart steps: "hour", "day" or "month"
    public DateTime From, To;              // the period: hours in [From, To)
    public DateTime PrevFrom, PrevTo;      // the period before it, for the change
    public ModelRow Total, Prev;
    public List<ModelRow> Models;          // most tokens first
    public long[] Series, SeriesReq;       // tokens and requests per step, oldest first
    public DateTime[] SlotStart;
}

// Everything the parser carries from line to line, per log folder: each folder is
// written by its own server, so their timing blocks and sessions never mix.
class ParserState {
    public string Name, Dir;
    public DateTime Ts = DateTime.MinValue;
    public DateTime RunStart = DateTime.MinValue;
    public string LastModel = "";
    public bool Pending;
    public long PPp, PTg, PCtx;
    public double PPpMs, PTgMs;
    public DateTime PAt;
    public DateTime SegStart = DateTime.MinValue;
    public string SegModel = "", SegReason = "";
    public bool LoadPending;
    public DateTime LoadAt;
    public string LiveKind = "idle", LiveModel = "";
    public double LiveTgTps, LiveProgress;
    public DateTime LastActivity = DateTime.MinValue;
    public long CtxSlot;
    public LastRequest Last;
    public long Requests;

    // what "most recently active" means when two servers have written logs
    public DateTime Recent {
        get {
            // Ts: the newest line this server wrote, whatever it was
            DateTime t = LastActivity;
            if (Ts > t) t = Ts;
            if (RunStart > t) t = RunStart;
            if (Last != null && Last.At > t) t = Last.At;
            return t;
        }
    }
}

public class LogMonitor {
    readonly List<ParserState> sources = new List<ParserState>();
    readonly string cachePath;
    readonly int backfillDays;
    readonly object gate = new object();
    Thread worker;
    volatile bool stop;
    public int PollMs = 2000;

    Dictionary<string, long> offsets = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
    Dictionary<string, Bucket> buckets = new Dictionary<string, Bucket>();
    long bytesTotal, bytesDone;
    bool caughtUp;
    string error;
    DateTime lastSave = DateTime.MinValue;
    bool dirty;

    static readonly Regex FileRe = new Regex(@"(\d{4}-\d{2}-\d{2})\.(\d+)\.log$", RegexOptions.IgnoreCase);
    static readonly Regex NumRe = new Regex(@"=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens");
    static readonly Regex TgRe = new Regex(@"tg\s*=\s*([\d.]+)\s*t/s");
    static readonly Regex CtxRe = new Regex(@"stop processing: n_tokens = (\d+)");
    static readonly Regex SlotRe = new Regex(@"n_ctx_slot = (\d+)");
    static readonly Regex ProgRe = new Regex(@"Prompt processing progress: ([\d.]+)%");

    // names: a short label per folder ("main", "bionic"); dirs: the server-logs folders.
    public LogMonitor(string[] names, string[] dirs, string cacheFile, int backfill) {
        for (int i = 0; i < dirs.Length; i++) {
            var st = new ParserState();
            st.Dir = dirs[i].TrimEnd('\\', '/');
            st.Name = (names != null && i < names.Length && !string.IsNullOrEmpty(names[i])) ? names[i] : ("logs" + i);
            sources.Add(st);
        }
        cachePath = cacheFile; backfillDays = backfill;
    }

    public void Start() {
        if (worker != null) return;
        try { LoadCache(); } catch (Exception e) { error = "cache: " + e.Message; }
        stop = false;
        worker = new Thread(Loop);
        worker.IsBackground = true;
        worker.Priority = ThreadPriority.BelowNormal;
        worker.Name = "localtokens-logs";
        worker.Start();
    }

    public void Stop() {
        stop = true;
        if (worker != null) { worker.Join(3000); worker = null; }
        try { lock (gate) { SaveCache(); } } catch { }
    }

    void Loop() {
        while (!stop) {
            try { ScanOnce(); }
            catch (Exception e) { error = e.Message; }
            try {
                if (dirty && (DateTime.Now - lastSave).TotalSeconds > 60) { lock (gate) { SaveCache(); } }
            } catch (Exception e) { error = "cache: " + e.Message; }
            for (int i = 0; i < PollMs / 100 && !stop; i++) Thread.Sleep(100);
        }
    }

    static long SortKey(string path, out DateTime day) {
        day = DateTime.MinValue;
        Match m = FileRe.Match(path);
        if (!m.Success) return long.MaxValue;
        day = DateTime.ParseExact(m.Groups[1].Value, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        return day.Ticks / TimeSpan.TicksPerDay * 100000 + long.Parse(m.Groups[2].Value);
    }

    void ScanOnce() {
        long total = 0, done = 0;
        int found = 0;
        DateTime cutoff = backfillDays > 0 ? DateTime.Today.AddDays(-backfillDays) : DateTime.MinValue;
        var plan = new List<KeyValuePair<ParserState, List<string>>>();
        foreach (var st in sources) {
            var list = new List<KeyValuePair<long, string>>();
            if (Directory.Exists(st.Dir)) {
                found++;
                foreach (string f in Directory.GetFiles(st.Dir, "*.log", SearchOption.AllDirectories)) {
                    DateTime day;
                    long k = SortKey(f, out day);
                    if (k == long.MaxValue) continue;
                    long len = new FileInfo(f).Length;
                    lock (gate) {
                        if (day < cutoff && !offsets.ContainsKey(f)) { offsets[f] = len; dirty = true; }
                        long off;
                        offsets.TryGetValue(f, out off);
                        done += Math.Min(off, len);
                    }
                    list.Add(new KeyValuePair<long, string>(k, f));
                    total += len;
                }
            }
            list.Sort((a, b) => a.Key.CompareTo(b.Key));
            var paths = new List<string>();
            foreach (var kv in list) paths.Add(kv.Value);
            plan.Add(new KeyValuePair<ParserState, List<string>>(st, paths));
        }
        bytesTotal = total; bytesDone = done;
        error = found == 0 ? "no LM Studio log folder found" : null;
        // Folders are read one after the other, each in date order with its own state.
        foreach (var p in plan) {
            foreach (string f in p.Value) {
                if (stop) return;
                ReadFile(p.Key, f);
            }
        }
        caughtUp = true;
    }

    void ReadFile(ParserState st, string path) {
        long off;
        lock (gate) { offsets.TryGetValue(path, out off); }
        long len = new FileInfo(path).Length;
        if (len < off) off = 0;               // file replaced: read it again
        if (len == off) return;
        byte[] buf = new byte[4 * 1024 * 1024];
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            fs.Seek(off, SeekOrigin.Begin);
            while (!stop) {
                int n = fs.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                int end = Array.LastIndexOf(buf, (byte)'\n', n - 1);
                int use;
                if (end < 0) {
                    if (n < buf.Length) break;     // half a line at the end: next time
                    use = n;                       // one enormous line: take it whole
                } else use = end + 1;
                string text = Encoding.UTF8.GetString(buf, 0, use);
                lock (gate) {
                    int start = 0;
                    while (start < text.Length) {
                        int nl = text.IndexOf('\n', start);
                        if (nl < 0) nl = text.Length;
                        int l = nl - start;
                        if (l > 0 && text[nl - 1] == '\r') l--;
                        if (l > 0) Line(st, text.Substring(start, l));
                        start = nl + 1;
                    }
                    off += use;
                    offsets[path] = off;
                    bytesDone += use;
                    dirty = true;
                }
                if (use < n) fs.Seek(off, SeekOrigin.Begin);
            }
        }
    }

    // Feed lines directly - used by the tests.
    public void FeedLines(int source, string[] lines) {
        lock (gate) { foreach (string l in lines) Line(sources[source], l); }
    }

    static bool TryTs(string s, out DateTime t) {
        t = DateTime.MinValue;
        // [2026-10-10 07:00:10]
        if (s.Length < 21 || s[0] != '[' || s[20] != ']' || s[5] != '-' || s[11] != ' ') return false;
        try {
            t = new DateTime(Num(s, 1, 4), Num(s, 6, 2), Num(s, 9, 2), Num(s, 12, 2), Num(s, 15, 2), Num(s, 18, 2));
            return true;
        } catch { return false; }
    }

    static int Num(string s, int i, int n) {
        int v = 0;
        for (int k = 0; k < n; k++) {
            int d = s[i + k] - '0';
            if (d < 0 || d > 9) throw new FormatException();
            v = v * 10 + d;
        }
        return v;
    }

    static bool IsEmbedding(string m) { return m.IndexOf("embed", StringComparison.OrdinalIgnoreCase) >= 0; }

    static void NewSegment(ParserState st, DateTime at, string model, string reason) {
        st.SegStart = at; st.SegModel = model; st.SegReason = reason;
    }

    void Line(ParserState st, string s) {
        int p = 0;
        DateTime t;
        if (TryTs(s, out t)) {
            st.Ts = t; p = 21;
            if (p < s.Length && s[p] == '[') {                       // [LEVEL]
                int e = s.IndexOf(']', p);
                if (e < 0) return;
                string level = s.Substring(p + 1, e - p - 1);
                p = e + 1;
                if (p < s.Length && s[p] == '[') {                   // [tag]: a model, the server, the authenticator
                    int e2 = s.IndexOf(']', p);
                    if (e2 < 0) return;
                    string tag = s.Substring(p + 1, e2 - p - 1);
                    string rest = s.Substring(e2 + 1);
                    if (tag == "LM STUDIO SERVER") {
                        if (rest.Contains("HTTP server listening")) {
                            if (st.Pending) Finish(st, st.LastModel);
                            st.RunStart = st.Ts;
                            NewSegment(st, st.Ts, "", "server");
                            st.LoadPending = false;
                            st.LiveKind = "idle";
                        }
                        return;
                    }
                    if (tag.StartsWith("LMSAuthenticator")) return;
                    // a model's line closes the timing block before it
                    if (st.Pending) Finish(st, tag);
                    // the first model line after "loading model" names what was loaded
                    if (st.LoadPending) {
                        st.LoadPending = false;
                        if (!IsEmbedding(tag)) NewSegment(st, st.LoadAt, tag, "load");
                    }
                    st.LastModel = tag;
                    if (level == "ERROR") Add(st, tag, st.Ts).Err++;
                    if (rest.Contains("Prompt processing progress")) {
                        Match m = ProgRe.Match(rest);
                        if (m.Success) st.LiveProgress = Dbl(m.Groups[1].Value);
                        st.LiveKind = "prompt"; st.LiveModel = tag; st.LastActivity = st.Ts;
                    } else if (rest.Contains("Running chat completion") || rest.Contains("Streaming response")) {
                        st.LiveKind = "prompt"; st.LiveModel = tag; st.LastActivity = st.Ts; st.LiveProgress = 0;
                    } else if (rest.Contains("Finished streaming response") || rest.Contains("Generated prediction")) {
                        st.LiveKind = "idle"; st.LastActivity = st.Ts;
                    }
                    return;
                }
            }
        }
        // llama.cpp lines: with or without the timestamp
        if (s.IndexOf("print_timing", p, StringComparison.Ordinal) >= 0) {
            if (s.Contains("prompt eval time")) {
                if (st.Pending) Finish(st, st.LastModel);
                Match m = NumRe.Match(s);
                if (m.Success) {
                    st.Pending = true; st.PPpMs = Dbl(m.Groups[1].Value); st.PPp = long.Parse(m.Groups[2].Value);
                    st.PTg = 0; st.PTgMs = 0; st.PCtx = 0; st.PAt = st.Ts;
                }
            } else if (st.Pending && st.PTgMs == 0 && s.Contains(" eval time")) {
                Match m = NumRe.Match(s);
                if (m.Success) { st.PTgMs = Dbl(m.Groups[1].Value); st.PTg = long.Parse(m.Groups[2].Value); }
            } else if (s.Contains("n_gen =")) {
                Match m = TgRe.Match(s);
                if (m.Success) st.LiveTgTps = Dbl(m.Groups[1].Value);
                st.LiveKind = "gen"; st.LastActivity = st.Ts;
            } else if (s.Contains("prompt processing, n_tokens")) {
                st.LiveKind = "prompt"; st.LastActivity = st.Ts;
            }
            return;
        }
        if (st.Pending && s.Contains("stop processing: n_tokens")) {
            Match m = CtxRe.Match(s);
            if (m.Success) st.PCtx = long.Parse(m.Groups[1].Value);
            return;
        }
        if (s.Contains("load_model: loading model")) {
            st.LoadPending = true; st.LoadAt = st.Ts;
            return;
        }
        if (s.Contains("n_ctx_slot =")) {
            Match m = SlotRe.Match(s);
            if (m.Success) st.CtxSlot = long.Parse(m.Groups[1].Value);
        }
    }

    static double Dbl(string v) { return double.Parse(v, CultureInfo.InvariantCulture); }

    // Bucket key: source | session segment | hour | model
    Bucket Add(ParserState st, string model, DateTime at) {
        DateTime hour = new DateTime(at.Year, at.Month, at.Day, at.Hour, 0, 0);
        var inv = CultureInfo.InvariantCulture;
        string key = st.Name + "|" + st.SegStart.Ticks.ToString(inv) + "|" + hour.Ticks.ToString(inv) + "|" + model;
        Bucket b;
        if (!buckets.TryGetValue(key, out b)) { b = new Bucket(); buckets[key] = b; }
        return b;
    }

    void Finish(ParserState st, string model) {
        st.Pending = false;
        if (string.IsNullOrEmpty(model)) model = "(unknown)";
        if (!IsEmbedding(model)) {
            if (st.SegModel.Length == 0) st.SegModel = model;          // first request after a server start
            else if (model != st.SegModel) NewSegment(st, st.PAt, model, "switch");
        }
        Bucket b = Add(st, model, st.PAt);
        b.Req++; b.Pp += st.PPp; b.Tg += st.PTg; b.PpMs += st.PPpMs; b.TgMs += st.PTgMs;
        b.Cached += st.PCtx > 0 ? Math.Max(0, st.PCtx - st.PPp - st.PTg + 1) : 0;
        var r = new LastRequest();
        r.At = st.PAt; r.Model = model; r.Pp = st.PPp; r.Tg = st.PTg; r.Ctx = st.PCtx; r.PpMs = st.PPpMs; r.TgMs = st.PTgMs;
        st.Last = r;
        st.Requests++;
    }

    // ------------------------------------------------------------ snapshot ----

    public Snapshot GetSnapshot(bool byModel) {
        var s = new Snapshot();
        DateTime now = DateTime.Now;
        DateTime hourNow = new DateTime(now.Year, now.Month, now.Day, now.Hour, 0, 0);
        DateTime weekStart = now.Date.AddDays(-6);
        lock (gate) {
            s.CaughtUp = caughtUp;
            s.CatchUpPct = bytesTotal > 0 ? Math.Min(100.0, 100.0 * bytesDone / bytesTotal) : 0;
            s.Error = error;

            ParserState act = null;
            foreach (var st in sources) if (act == null || st.Recent > act.Recent) act = st;
            s.Sources = new List<SourceInfo>();
            foreach (var st in sources) {
                var si = new SourceInfo();
                si.Name = st.Name; si.Dir = st.Dir; si.Exists = Directory.Exists(st.Dir);
                si.LastSeen = st.Ts; si.Requests = st.Requests;
                s.Sources.Add(si);
            }
            s.ActiveSource = act.Name;
            s.RunStart = act.RunStart;
            s.SessionStart = byModel ? act.SegStart : act.RunStart;
            s.SessionReason = byModel ? act.SegReason : "server";
            s.SessionModel = act.SegModel;

            var sess = new Dictionary<string, ModelRow>();
            var today = new Dictionary<string, ModelRow>();
            var week = new ModelRow(); week.Model = "";
            var all = new ModelRow(); all.Model = "";
            s.FirstSeen = DateTime.MaxValue;
            string segKey = act.SegStart.Ticks.ToString(CultureInfo.InvariantCulture);
            foreach (var kv in buckets) {
                string[] k = kv.Key.Split(new char[] { '|' }, 4);
                if (k.Length < 4) continue;
                long seg = long.Parse(k[1], CultureInfo.InvariantCulture);
                DateTime hour = new DateTime(long.Parse(k[2], CultureInfo.InvariantCulture));
                string model = k[3];
                Bucket b = kv.Value;
                Acc(all, b);
                if (hour < s.FirstSeen && b.Req > 0) s.FirstSeen = hour;
                if (k[0] == act.Name && (byModel ? k[1] == segKey : seg >= act.RunStart.Ticks)) Acc(Row(sess, model), b);
                if (hour.Date == now.Date) Acc(Row(today, model), b);
                if (hour >= weekStart) Acc(week, b);
                int ago = (int)Math.Round((hourNow - hour).TotalHours);
                if (ago >= 0 && ago < 24) s.Hourly[23 - ago] += b.Pp + b.Tg;
            }
            s.AllTime = all;
            s.Week = week;
            s.HasData = all.Req > 0;
            s.SessionModels = Sorted(sess);
            s.TodayModels = Sorted(today);
            s.Session = Sum(s.SessionModels);
            s.Today = Sum(s.TodayModels);
            bool fresh = (now - act.LastActivity).TotalSeconds < 20;
            s.LiveKind = fresh ? act.LiveKind : "idle";
            s.LiveModel = act.LiveModel;
            s.LiveTgTps = act.LiveTgTps;
            s.LiveProgress = act.LiveProgress;
            s.LastActivity = act.LastActivity;
            s.CtxSlot = act.CtxSlot;
            s.Last = act.Last;
        }
        return s;
    }

    static ModelRow Row(Dictionary<string, ModelRow> d, string m) {
        ModelRow r;
        if (!d.TryGetValue(m, out r)) { r = new ModelRow(); r.Model = m; d[m] = r; }
        return r;
    }
    static void Acc(ModelRow r, Bucket b) {
        r.Req += b.Req; r.Pp += b.Pp; r.Tg += b.Tg; r.Cached += b.Cached; r.Err += b.Err;
        r.PpMs += b.PpMs; r.TgMs += b.TgMs;
    }
    static List<ModelRow> Sorted(Dictionary<string, ModelRow> d) {
        var l = new List<ModelRow>(d.Values);
        l.Sort((a, b) => b.Tokens.CompareTo(a.Tokens));
        return l;
    }
    static ModelRow Sum(List<ModelRow> l) {
        var r = new ModelRow(); r.Model = "";
        foreach (var x in l) {
            r.Req += x.Req; r.Pp += x.Pp; r.Tg += x.Tg; r.Cached += x.Cached; r.Err += x.Err;
            r.PpMs += x.PpMs; r.TgMs += x.TgMs;
        }
        return r;
    }

    // ------------------------------------------------------------- report ----
    // Totals for one period ("24h", "today", "week", "month", "year"), every log folder
    // combined, plus the same totals for the period just before it and a series of
    // tokens per hour, day or month for the chart. Built from the hourly buckets, so
    // it covers everything ever read, not only the last week.

    public Report GetReport(string period) { return GetReport(period, DateTime.Now); }

    public Report GetReport(string period, DateTime now) {
        var r = new Report();
        DateTime hourNow = new DateTime(now.Year, now.Month, now.Day, now.Hour, 0, 0);
        DateTime monthNow = new DateTime(now.Year, now.Month, 1);
        switch (period) {
            case "today":
                r.Unit = "hour"; r.From = now.Date; r.To = hourNow.AddHours(1);
                r.PrevFrom = r.From.AddDays(-1); r.PrevTo = r.To.AddDays(-1);      // yesterday up to this hour
                break;
            case "week":
                r.Unit = "day"; r.From = now.Date.AddDays(-6); r.To = now.Date.AddDays(1);
                r.PrevFrom = r.From.AddDays(-7); r.PrevTo = r.From;
                break;
            case "month":
                r.Unit = "day"; r.From = now.Date.AddDays(-29); r.To = now.Date.AddDays(1);
                r.PrevFrom = r.From.AddDays(-30); r.PrevTo = r.From;
                break;
            case "year":
                r.Unit = "month"; r.From = monthNow.AddMonths(-11); r.To = monthNow.AddMonths(1);
                r.PrevFrom = r.From.AddMonths(-12); r.PrevTo = r.From;
                break;
            default:
                period = "24h";
                r.Unit = "hour"; r.From = hourNow.AddHours(-23); r.To = hourNow.AddHours(1);
                r.PrevFrom = r.From.AddHours(-24); r.PrevTo = r.From;
                break;
        }
        r.Period = period;
        int slots = Slot(r.Unit, r.From, r.To);
        r.Series = new long[slots];
        r.SeriesReq = new long[slots];
        r.SlotStart = new DateTime[slots];
        for (int i = 0; i < slots; i++)
            r.SlotStart[i] = r.Unit == "hour" ? r.From.AddHours(i) : r.Unit == "day" ? r.From.AddDays(i) : r.From.AddMonths(i);

        var models = new Dictionary<string, ModelRow>();
        var prev = new ModelRow(); prev.Model = "";
        lock (gate) {
            foreach (var kv in buckets) {
                string[] k = kv.Key.Split(new char[] { '|' }, 4);
                if (k.Length < 4) continue;
                DateTime hour = new DateTime(long.Parse(k[2], CultureInfo.InvariantCulture));
                Bucket b = kv.Value;
                if (hour >= r.From && hour < r.To) {
                    Acc(Row(models, k[3]), b);
                    int i = Slot(r.Unit, r.From, hour);
                    r.Series[i] += b.Pp + b.Tg;
                    r.SeriesReq[i] += b.Req;
                } else if (hour >= r.PrevFrom && hour < r.PrevTo) {
                    Acc(prev, b);
                }
            }
        }
        r.Models = Sorted(models);
        r.Total = Sum(r.Models);
        r.Prev = prev;
        return r;
    }

    // Which hour, day or month after "from" a time falls in.
    static int Slot(string unit, DateTime from, DateTime t) {
        if (unit == "hour") return (int)Math.Round((t - from).TotalHours);
        if (unit == "day") return (int)Math.Round((t.Date - from).TotalDays);
        return (t.Year - from.Year) * 12 + t.Month - from.Month;
    }

    // ------------------------------------------------------------- export ----
    // One row per day and model, every log folder combined.

    public int ExportCsv(string path) { return ExportCsv(path, DateTime.MinValue, DateTime.MaxValue); }

    // Only the hours in [from, to): the Reports tab exports the period it shows.
    public int ExportCsv(string path, DateTime from, DateTime to) {
        var rows = new SortedDictionary<string, ModelRow>(StringComparer.Ordinal);
        lock (gate) {
            foreach (var kv in buckets) {
                string[] k = kv.Key.Split(new char[] { '|' }, 4);
                if (k.Length < 4) continue;
                DateTime hour = new DateTime(long.Parse(k[2], CultureInfo.InvariantCulture));
                if (hour < from || hour >= to) continue;
                string key = hour.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + "\t" + k[3];
                ModelRow r;
                if (!rows.TryGetValue(key, out r)) { r = new ModelRow(); r.Model = k[3]; rows[key] = r; }
                Acc(r, kv.Value);
            }
        }
        var inv = CultureInfo.InvariantCulture;
        var sb = new StringBuilder();
        sb.Append("date,model,requests,prompt_tokens,cached_prompt_tokens,generated_tokens,total_tokens,gen_tokens_per_sec,prompt_tokens_per_sec,errors\r\n");
        foreach (var kv in rows) {
            ModelRow r = kv.Value;
            string date = kv.Key.Substring(0, 10);
            sb.Append(date).Append(',').Append(Csv(r.Model)).Append(',')
              .Append(r.Req.ToString(inv)).Append(',').Append(r.Pp.ToString(inv)).Append(',')
              .Append(r.Cached.ToString(inv)).Append(',').Append(r.Tg.ToString(inv)).Append(',')
              .Append(r.Tokens.ToString(inv)).Append(',').Append(r.GenTps.ToString("0.0", inv)).Append(',')
              .Append(r.PromptTps.ToString("0.0", inv)).Append(',').Append(r.Err.ToString(inv)).Append("\r\n");
        }
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
        return rows.Count;
    }

    static string Csv(string v) {
        if (v.IndexOfAny(new char[] { ',', '"', '\n' }) < 0) return v;
        return "\"" + v.Replace("\"", "\"\"") + "\"";
    }

    // --------------------------------------------------------------- cache ----
    // Plain text, one record per line: what was read, the totals, each folder's parser state.

    const string CacheVersion = "localtokens-cache 1";

    ParserState Find(string name) {
        foreach (var st in sources) if (st.Name == name) return st;
        return null;
    }

    void SaveCache() {
        if (string.IsNullOrEmpty(cachePath)) return;
        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;
        sb.Append(CacheVersion).Append('\n');
        foreach (var st in sources) {
            sb.Append("src\t").Append(st.Name).Append('\t').Append(st.Dir).Append('\t')
              .Append(st.Ts.Ticks.ToString(inv)).Append('\t').Append(st.RunStart.Ticks.ToString(inv)).Append('\t')
              .Append(st.SegStart.Ticks.ToString(inv)).Append('\t').Append(st.SegModel).Append('\t')
              .Append(st.SegReason).Append('\t').Append(st.LastModel).Append('\t')
              .Append(st.CtxSlot.ToString(inv)).Append('\t').Append(st.Requests.ToString(inv)).Append('\n');
            if (st.Last != null) {
                LastRequest l = st.Last;
                sb.Append("last\t").Append(st.Name).Append('\t').Append(l.At.Ticks.ToString(inv)).Append('\t')
                  .Append(l.Model).Append('\t').Append(l.Pp.ToString(inv)).Append('\t').Append(l.Tg.ToString(inv)).Append('\t')
                  .Append(l.Ctx.ToString(inv)).Append('\t').Append(l.PpMs.ToString("R", inv)).Append('\t')
                  .Append(l.TgMs.ToString("R", inv)).Append('\n');
            }
        }
        foreach (var kv in offsets)
            sb.Append("file\t").Append(kv.Key).Append('\t').Append(kv.Value.ToString(inv)).Append('\n');
        foreach (var kv in buckets) {
            Bucket b = kv.Value;
            sb.Append("b\t").Append(kv.Key.Replace('|', '\t')).Append('\t')
              .Append(b.Req.ToString(inv)).Append('\t').Append(b.Pp.ToString(inv)).Append('\t')
              .Append(b.Tg.ToString(inv)).Append('\t').Append(b.Cached.ToString(inv)).Append('\t')
              .Append(b.PpMs.ToString("R", inv)).Append('\t').Append(b.TgMs.ToString("R", inv)).Append('\t')
              .Append(b.Err.ToString(inv)).Append('\n');
        }
        string dir = Path.GetDirectoryName(cachePath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
        string tmp = cachePath + ".tmp";
        File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
        if (File.Exists(cachePath)) File.Delete(cachePath);
        File.Move(tmp, cachePath);
        lastSave = DateTime.Now;
        dirty = false;
    }

    void LoadCache() {
        if (string.IsNullOrEmpty(cachePath) || !File.Exists(cachePath)) return;
        string[] lines = File.ReadAllLines(cachePath, Encoding.UTF8);
        if (lines.Length == 0 || lines[0] != CacheVersion) return;
        var inv = CultureInfo.InvariantCulture;
        // A folder that is no longer watched, or moved: its totals are dropped and
        // its files read again if it comes back.
        var keep = new HashSet<string>();
        foreach (string line in lines) {
            string[] f = line.Split('\t');
            if (f[0] != "src" || f.Length < 11) continue;
            ParserState st = Find(f[1]);
            if (st == null || !string.Equals(st.Dir, f[2], StringComparison.OrdinalIgnoreCase)) continue;
            keep.Add(st.Name);
            st.Ts = new DateTime(long.Parse(f[3], inv));
            st.RunStart = new DateTime(long.Parse(f[4], inv));
            st.SegStart = new DateTime(long.Parse(f[5], inv));
            st.SegModel = f[6]; st.SegReason = f[7]; st.LastModel = f[8];
            st.CtxSlot = long.Parse(f[9], inv); st.Requests = long.Parse(f[10], inv);
        }
        foreach (string line in lines) {
            string[] f = line.Split('\t');
            switch (f[0]) {
                case "last": {
                    if (f.Length < 9 || !keep.Contains(f[1])) break;
                    var r = new LastRequest();
                    r.At = new DateTime(long.Parse(f[2], inv)); r.Model = f[3];
                    r.Pp = long.Parse(f[4], inv); r.Tg = long.Parse(f[5], inv); r.Ctx = long.Parse(f[6], inv);
                    r.PpMs = double.Parse(f[7], inv); r.TgMs = double.Parse(f[8], inv);
                    Find(f[1]).Last = r;
                    break;
                }
                case "file": {
                    if (f.Length < 3) break;
                    foreach (var st in sources) {
                        if (keep.Contains(st.Name) && f[1].StartsWith(st.Dir, StringComparison.OrdinalIgnoreCase)) {
                            offsets[f[1]] = long.Parse(f[2], inv);
                            break;
                        }
                    }
                    break;
                }
                case "b": {
                    if (f.Length < 12 || !keep.Contains(f[1])) break;
                    var b = new Bucket();
                    b.Req = long.Parse(f[5], inv); b.Pp = long.Parse(f[6], inv); b.Tg = long.Parse(f[7], inv);
                    b.Cached = long.Parse(f[8], inv); b.PpMs = double.Parse(f[9], inv); b.TgMs = double.Parse(f[10], inv);
                    b.Err = long.Parse(f[11], inv);
                    buckets[f[1] + "|" + f[2] + "|" + f[3] + "|" + f[4]] = b;
                    break;
                }
            }
        }
    }
}
}
