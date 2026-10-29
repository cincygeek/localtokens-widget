# ------------------------------------------------------------------ view ----
# Draws the window from the reader's snapshot and the API's list of loaded models.

$Colors = @{
    accent = '#FF2DD4BF'; accentDim = '#7F2DD4BF'
    ok = '#FF4ADE80'; warn = '#FFFBBF24'; crit = '#FFF87171'; dead = '#FF6B7280'
    text2 = '#FFD4D4D8'; muted = '#FF8B8B94'; dim = '#FF71717A'
}
$BarWidth = 238.0
$script:Brushes = @{}

function Get-Brush([string]$hex) {
    if (-not $script:Brushes.ContainsKey($hex)) {
        $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
        $b.Freeze()
        $script:Brushes[$hex] = $b
    }
    return $script:Brushes[$hex]
}

# ---------------------------------------------------------------- format ----

function Format-Tok([double]$n) {
    if ($n -ge 1e9) { return '{0:0.##}B' -f ($n / 1e9) }
    if ($n -ge 1e6) { return '{0:0.##}M' -f ($n / 1e6) }
    if ($n -ge 1e5) { return '{0:0}k' -f ($n / 1e3) }
    if ($n -ge 1e3) { return '{0:0.#}k' -f ($n / 1e3) }
    return '{0:0}' -f $n
}

function Format-Since([datetime]$since) {
    $s = (Get-Date) - $since
    if ($s.TotalDays -ge 1) { return '{0}d {1}h' -f [math]::Floor($s.TotalDays), $s.Hours }
    if ($s.TotalHours -ge 1) { return '{0}h {1:00}m' -f [math]::Floor($s.TotalHours), $s.Minutes }
    return '{0}m' -f [math]::Max(0, $s.Minutes)
}

# "zai-org/glm-4.7-flash" -> "glm-4.7-flash"
function Get-ShortModel([string]$id) {
    if (-not $id) { return '' }
    $i = $id.LastIndexOf('/')
    if ($i -ge 0) { return $id.Substring($i + 1) }
    return $id
}

function Get-CtxLevel([double]$pct) {
    if ($pct -ge [double]$script:Cfg.critPercent) { return 'crit' }
    if ($pct -ge [double]$script:Cfg.warnPercent) { return 'warn' }
    return 'ok'
}

# ------------------------------------------------------------- elements ----

# One "left ... right" line in the details.
function New-Row([string]$left, [string]$right, [string]$leftColor = $Colors.text2, [string]$tip = $null) {
    $g = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(1, 'Star')
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $a = New-Object System.Windows.Controls.TextBlock
    $a.Text = $left; $a.FontFamily = 'Segoe UI'; $a.FontSize = 10.5; $a.Foreground = Get-Brush $leftColor
    $a.TextTrimming = 'CharacterEllipsis'; $a.Margin = '0,0,8,0'
    $b = New-Object System.Windows.Controls.TextBlock
    $b.Text = $right; $b.FontFamily = 'Segoe UI'; $b.FontSize = 10; $b.Foreground = Get-Brush $Colors.muted
    [System.Windows.Controls.Grid]::SetColumn($b, 1)
    [void]$g.Children.Add($a); [void]$g.Children.Add($b)
    $g.Margin = '0,0,0,1'
    if ($tip) { $g.ToolTip = $tip; $g.Background = [System.Windows.Media.Brushes]::Transparent }
    return $g
}

$script:BarsKey = $null
function Set-HourlyBars([long[]]$hourly) {
    $key = "$((Get-Date).Hour)|$($hourly -join ',')"
    if ($key -eq $script:BarsKey) { return }
    $script:BarsKey = $key
    $UI.Hourly.Children.Clear()
    $max = 0; foreach ($v in $hourly) { if ($v -gt $max) { $max = $v } }
    $w = ($BarWidth - 23 * 2) / 24
    $inv = [Globalization.CultureInfo]::InvariantCulture
    for ($i = 0; $i -lt 24; $i++) {
        $r = New-Object System.Windows.Shapes.Rectangle
        $h = $(if ($max -gt 0) { [math]::Max(1.5, 40.0 * $hourly[$i] / $max) } else { 1.5 })
        $r.Width = $w; $r.Height = $h; $r.RadiusX = 1; $r.RadiusY = 1
        $r.Fill = Get-Brush $(if ($i -eq 23) { $Colors.accent } else { $Colors.accentDim })
        [System.Windows.Controls.Canvas]::SetLeft($r, $i * ($w + 2))
        [System.Windows.Controls.Canvas]::SetTop($r, 42 - $h)
        $label = (Get-Date).AddHours($i - 23).ToString('h tt', $inv).ToLower()
        $r.ToolTip = "$label  ·  $(Format-Tok $hourly[$i]) tokens"
        [void]$UI.Hourly.Children.Add($r)
    }
    $UI.HourStart.Text = (Get-Date).AddHours(-23).ToString('h tt', $inv).ToLower()
}

# ------------------------------------------------------------------ draw ----

$script:DetKey = $null
$script:LastSnap = $null

function Update-View {
    if (-not $script:Reader) { return }
    $s = $script:Reader.GetSnapshot(([string]$script:Cfg.sessionMode) -ne 'server')
    $script:LastSnap = $s
    $apiFresh = Test-ApiFresh
    $loaded = @($script:Loaded | Where-Object { $_ -and $_.type -ne 'embeddings' })

    # --- status ---------------------------------------------------------------
    $offline = $false
    if ($s.LiveKind -eq 'gen') {
        $UI.Status.Text = 'Generating'; $dot = $Colors.accent
    } elseif ($s.LiveKind -eq 'prompt') {
        $txt = 'Reading prompt'
        if ($s.LiveProgress -gt 0 -and $s.LiveProgress -lt 100) { $txt += '  {0:0}%' -f $s.LiveProgress }
        $UI.Status.Text = $txt; $dot = $Colors.warn
    } elseif ($apiFresh -or ([datetime]::Now - $s.LastActivity).TotalMinutes -lt 2) {
        $UI.Status.Text = 'Idle'; $dot = $Colors.muted
    } else {
        $UI.Status.Text = 'Server offline'; $dot = $Colors.dead; $offline = $true
    }
    $UI.Dot.Fill = Get-Brush $dot
    $multi = @($s.Sources | Where-Object { $_.Exists }).Count -gt 1
    $UI.SourceTag.Text = $(if ($multi) { $s.ActiveSource } else { '' })
    $UI.SourceTag.ToolTip = $(if ($multi) { "Showing the LM Studio server that wrote to this log folder last" } else { $null })

    # --- big number -----------------------------------------------------------
    if (-not $s.CaughtUp -and -not $s.HasData) {
        $UI.Big.Text = '--'
        $UI.BigUnit.Text = 'reading logs  {0:0}%' -f $s.CatchUpPct
    } else {
        $UI.Big.Text = Format-Tok ($s.Session.Pp + $s.Session.Tg)
        $UI.BigUnit.Text = $(if ($s.CaughtUp) { 'tokens this session' } else { 'tokens · reading logs {0:0}%' -f $s.CatchUpPct })
    }

    # --- model · quant · since ------------------------------------------------
    $model = $(if ($s.LiveModel) { $s.LiveModel } elseif ($s.Last) { $s.Last.Model } else { '' })
    $quant = ''
    $ctxMax = [long]$s.CtxSlot
    if ($loaded.Count) {
        $hit = $loaded | Where-Object { $_.id -eq $model } | Select-Object -First 1
        if (-not $hit -and (-not $model -or $s.LiveKind -eq 'idle')) { $hit = $loaded[0]; $model = $hit.id }
        if ($hit) { $quant = $hit.quant; if ($hit.ctx -gt 0 -and -not $ctxMax) { $ctxMax = $hit.ctx } }
    }
    $parts = @()
    if ($model) { $parts += (Get-ShortModel $model) }
    if ($quant) { $parts += $quant }
    if ($s.SessionStart -gt [datetime]::MinValue) {
        $since = Format-Since $s.SessionStart
        $parts += $(switch ($s.SessionReason) { 'load' { "loaded $since" } 'switch' { "switched $since" } default { "up $since" } })
    }
    $UI.ModelLine.Text = $(if ($parts.Count) { $parts -join '  ·  ' } else { 'no requests yet' })
    $UI.ModelLine.ToolTip = $(if ($s.SessionStart -gt [datetime]::MinValue) {
        $when = $s.SessionStart.ToString('ddd MMM d, h:mm tt')
        $m = Get-ShortModel $s.SessionModel
        $tip = switch ($s.SessionReason) {
            'load'   { "This session: since $m was loaded, $when" }
            'switch' { "This session: since requests switched to $m, $when" }
            default  { "This session: since the LM Studio server started, $when" }
        }
        if ($s.RunStart -gt [datetime]::MinValue) { $tip += "`nServer up $(Format-Since $s.RunStart)" }
        $tip
    } else { $null })

    # --- speed: live while generating, otherwise the last request ---------------
    $cur = $(if ($s.LiveKind -eq 'gen' -and $s.LiveTgTps -gt 0) { $s.LiveTgTps }
             elseif ($s.Last -and $s.Last.TgMs -gt 0) { $s.Last.Tg / ($s.Last.TgMs / 1000.0) } else { 0 })
    $UI.GenLine.Text = $(if ($cur -gt 0) { '{0:0.0} tok/s  ·  avg {1:0.0}' -f $cur, $s.Session.GenTps } else { '—' })
    $scale = [math]::Max(1.0, [double]$script:Cfg.speedScale)
    $UI.GenBar.Width = [math]::Min($BarWidth, $BarWidth * $cur / $scale)
    $UI.GenBar.Background = Get-Brush $(if ($cur -gt 0 -and $cur -lt [double]$script:Cfg.slowTps) { $Colors.warn } else { $Colors.accent })

    # --- context of the last request -------------------------------------------
    if ($s.Last -and $s.Last.Ctx -gt 0 -and $ctxMax -gt 0) {
        $pct = [math]::Min(100.0, 100.0 * $s.Last.Ctx / $ctxMax)
        $UI.CtxLine.Text = '{0} / {1}' -f (Format-Tok $s.Last.Ctx), (Format-Tok $ctxMax)
        $UI.CtxBar.Width = $BarWidth * $pct / 100
        $UI.CtxBar.Background = Get-Brush $Colors[(Get-CtxLevel $pct)]
    } else {
        $UI.CtxLine.Text = '—'
        $UI.CtxBar.Width = 0
    }

    $UI.Foot.Text = '{0} req  ·  {1:0}% cached' -f $s.Session.Req, $s.Session.CachePct
    $UI.Foot.ToolTip = 'Share of prompt tokens LM Studio reused from its cache instead of processing again'
    $UI.FootRight.Text = "Today $(Format-Tok $s.Today.Tokens)"

    $UI.Stamp.Text = (Get-Date).ToString('h:mm:ss tt')
    $UI.ErrLine.Text = $(if ($s.Error) { $s.Error } else { '' })

    Update-Tray $s $cur $offline

    # --- details (rebuilt only when something in them changed) ---------------
    if ($UI.Details.Visibility -ne 'Visible') { return }
    Set-HourlyBars $s.Hourly
    $key = "$($s.Today.Tokens)|$($s.AllTime.Req)|$(if ($s.Last) { $s.Last.At.Ticks })|$apiFresh|" +
           "$(@($script:Loaded | ForEach-Object { $_.id }) -join ',')|$((Get-Date).Date.Ticks)"
    if ($key -eq $script:DetKey) { return }
    $script:DetKey = $key

    $UI.Totals.Children.Clear()
    $h24 = 0; foreach ($v in $s.Hourly) { $h24 += $v }
    [void]$UI.Totals.Children.Add((New-Row 'Last 24 hours' "$(Format-Tok $h24)"))
    [void]$UI.Totals.Children.Add((New-Row 'Today' ('{0}  ·  {1} req' -f (Format-Tok $s.Today.Tokens), $s.Today.Req)))
    [void]$UI.Totals.Children.Add((New-Row 'Last 7 days' ('{0}  ·  {1} req' -f (Format-Tok $s.Week.Tokens), $s.Week.Req)))
    $since = $(if ($s.FirstSeen -lt [datetime]::MaxValue) { $s.FirstSeen.ToString('MMM d, yyyy') } else { '' })
    $allTip = "$($s.AllTime.Req) requests`n$(Format-Tok $s.AllTime.Pp) prompt  ·  $(Format-Tok $s.AllTime.Tg) generated`n$(Format-Tok $s.AllTime.Cached) prompt tokens from cache`n$($s.AllTime.Err) errors"
    [void]$UI.Totals.Children.Add((New-Row $(if ($since) { "Since $since" } else { 'All time' }) ('{0}  ·  {1} req' -f (Format-Tok $s.AllTime.Tokens), $s.AllTime.Req) $Colors.text2 $allTip))

    $UI.Models.Children.Clear()
    $rows = @($s.TodayModels | Select-Object -First ([int]$script:Cfg.topModels))
    if (-not $rows.Count) { [void]$UI.Models.Children.Add((New-Row 'nothing yet today' '' $Colors.muted)) }
    foreach ($r in $rows) {
        $tip = "$($r.Model)`n$($r.Req) requests  ·  $(Format-Tok $r.Pp) prompt  ·  $(Format-Tok $r.Tg) generated`nprompt {0:0} tok/s  ·  {1:0}% cached" -f $r.PromptTps, $r.CachePct
        [void]$UI.Models.Children.Add((New-Row (Get-ShortModel $r.Model) ('{0}  ·  {1:0} tok/s' -f (Format-Tok $r.Tokens), $r.GenTps) $Colors.text2 $tip))
    }

    $UI.LastReq.Children.Clear()
    if ($s.Last) {
        $l = $s.Last
        $ctxTxt = $(if ($l.Ctx -gt 0) { "Prompt $(Format-Tok ($l.Ctx - $l.Tg)) ($(Format-Tok $l.Pp) new)" } else { "Prompt $(Format-Tok $l.Pp)" })
        [void]$UI.LastReq.Children.Add((New-Row $ctxTxt "$(Format-Tok $l.Tg) out"))
        $pps = $(if ($l.PpMs -gt 0) { $l.Pp / ($l.PpMs / 1000) } else { 0 })
        $tgs = $(if ($l.TgMs -gt 0) { $l.Tg / ($l.TgMs / 1000) } else { 0 })
        [void]$UI.LastReq.Children.Add((New-Row ('Prompt {0:0} tok/s  ·  gen {1:0.0} tok/s' -f $pps, $tgs) ('{0:0.0} s' -f (($l.PpMs + $l.TgMs) / 1000))))
        $UI.LastLbl.ToolTip = "$($l.Model)  ·  $($l.At.ToString('ddd h:mm:ss tt'))"
    } else {
        [void]$UI.LastReq.Children.Add((New-Row 'no requests yet' '' $Colors.muted))
    }

    $UI.LoadedList.Children.Clear()
    if (-not $apiFresh) {
        [void]$UI.LoadedList.Children.Add((New-Row 'LM Studio server not reachable' '' $Colors.muted "Asked $($script:Cfg.apiUrl)/api/v0/models"))
    } elseif (-not @($script:Loaded).Count) {
        [void]$UI.LoadedList.Children.Add((New-Row 'nothing loaded' '' $Colors.muted))
    } else {
        foreach ($m in $script:Loaded) {
            $right = $(if ($m.type -eq 'embeddings') { 'embedding' } else { "$($m.quant)  ·  $(Format-Tok $m.ctx) ctx" })
            [void]$UI.LoadedList.Children.Add((New-Row (Get-ShortModel $m.id) $right $Colors.text2 $m.id))
        }
    }

    $UI.SourceList.Children.Clear()
    foreach ($src in $s.Sources) {
        $right = $(if (-not $src.Exists) { 'not found' }
                   elseif ($src.LastSeen -gt [datetime]::MinValue) { "$(Format-Since $src.LastSeen) ago" } else { 'empty' })
        $color = $(if ($src.Name -eq $s.ActiveSource -and $src.Exists) { $Colors.text2 } else { $Colors.muted })
        [void]$UI.SourceList.Children.Add((New-Row "$($src.Name)  ·  $($src.Requests) req" $right $color $src.Dir))
    }
}
