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

    Update-Report

    # --- details (rebuilt only when something in them changed) ---------------
    if ($UI.Details.Visibility -ne 'Visible' -or $UI.LivePanel.Visibility -ne 'Visible') { return }
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

# --------------------------------------------------------------- reports ----
# The Reports tab: totals for one period, built from the reader's hourly buckets.

$Periods = [ordered]@{ '24h' = '24h'; today = 'Today'; week = 'Week'; month = 'Month'; year = 'Year' }
$PeriodVs = @{ '24h' = 'previous 24 hours'; today = 'yesterday by this hour'; week = 'previous 7 days'
               month = 'previous 30 days'; year = 'previous 12 months' }
$script:RpKey = $null

function Format-Duration([double]$ms) {
    $m = [math]::Round($ms / 60000)
    if ($m -ge 60) { return '{0}h {1:00}m' -f [math]::Floor($m / 60), ($m % 60) }
    if ($m -ge 1) { return "${m}m" }
    return '{0:0}s' -f ($ms / 1000)
}

function Get-ReportPeriod {
    $p = ([string]$script:Cfg.reportPeriod).ToLower()
    if (-not $Periods.Contains($p)) { $p = '24h' }
    return $p
}

# Colour an element from the window's theme brushes, so a theme change recolours it.
function Set-Res($el, $prop, [string]$key) { $el.SetResourceReference($prop, $key) }

# The 24h | Today | Week | Month | Year buttons, made once.
function Initialize-PeriodBar {
    foreach ($id in $Periods.Keys) {
        $b = New-Object System.Windows.Controls.Border
        $b.CornerRadius = 4; $b.Padding = '0,3,0,4'; $b.Cursor = 'Hand'; $b.Tag = $id
        $b.Background = [System.Windows.Media.Brushes]::Transparent
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $Periods[$id]; $t.FontFamily = 'Segoe UI'; $t.FontSize = 10; $t.FontWeight = 'Medium'
        $t.HorizontalAlignment = 'Center'
        $b.Child = $t
        $b.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Set-ReportPeriod ([string]$s.Tag) })
        [void]$UI.PeriodBar.Children.Add($b)
    }
}

function Set-ReportPeriod([string]$p) {
    if ($script:Cfg.reportPeriod -ne $p) { $script:Cfg.reportPeriod = $p; Save-Config }
    $script:RpKey = $null
    Update-Report
}

# Tab and period buttons: the chosen one bright, the others muted.
function Update-TabStyles {
    $rep = $UI.ReportPanel.Visibility -eq 'Visible'
    $fg = [System.Windows.Controls.TextBlock]::ForegroundProperty
    $bg = [System.Windows.Controls.Border]::BackgroundProperty
    Set-Res $UI.TabLiveText $fg $(if ($rep) { 'Muted' } else { 'TextHi' })
    Set-Res $UI.TabReportsText $fg $(if ($rep) { 'TextHi' } else { 'Muted' })
    if ($rep) { $UI.TabLiveLine.Background = $null; Set-Res $UI.TabReportsLine $bg 'Accent' }
    else { Set-Res $UI.TabLiveLine $bg 'Accent'; $UI.TabReportsLine.Background = $null }
    $cur = Get-ReportPeriod
    foreach ($b in $UI.PeriodBar.Children) {
        if ([string]$b.Tag -eq $cur) { Set-Res $b $bg 'Bg'; Set-Res $b.Child $fg 'TextHi' }
        else { $b.Background = [System.Windows.Media.Brushes]::Transparent; Set-Res $b.Child $fg 'Muted' }
    }
}

# One "value over caption" cell of the totals grid.
function New-Stat([string]$value, [string]$label, [string]$color = $Colors.text2, [string]$tip = $null) {
    $p = New-Object System.Windows.Controls.StackPanel
    $p.Margin = '0,0,8,6'
    $v = New-Object System.Windows.Controls.TextBlock
    $v.Text = $value; $v.FontFamily = 'Segoe UI'; $v.FontSize = 13; $v.Foreground = Get-Brush $color
    $k = New-Object System.Windows.Controls.TextBlock
    $k.Text = $label; $k.FontFamily = 'Segoe UI'; $k.FontSize = 9; $k.Foreground = Get-Brush $Colors.dim
    [void]$p.Children.Add($v); [void]$p.Children.Add($k)
    if ($tip) { $p.ToolTip = $tip; $p.Background = [System.Windows.Media.Brushes]::Transparent }
    return $p
}

function Get-ReportRange($r) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    switch ($r.Period) {
        'today' { return 'Today, ' + $r.From.ToString('ddd MMM d', $inv) }
        'year'  { return $r.From.ToString('MMM yyyy', $inv) + ' – ' + $r.To.AddMonths(-1).ToString('MMM yyyy', $inv) }
        '24h'   { return 'Last 24 hours, since ' + $r.From.ToString('ddd ', $inv) + $r.From.ToString('h tt', $inv).ToLower() }
        default { return $r.From.ToString('MMM d', $inv) + ' – ' + $r.To.AddDays(-1).ToString('MMM d', $inv) }
    }
}

function Set-ReportChart($r) {
    $UI.RpChart.Children.Clear()
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $n = $r.Series.Length
    $max = 0; foreach ($v in $r.Series) { if ($v -gt $max) { $max = $v } }
    $gap = $(if ($n -gt 24) { 1.5 } else { 2 })
    $w = ($BarWidth - ($n - 1) * $gap) / $n
    for ($i = 0; $i -lt $n; $i++) {
        $rect = New-Object System.Windows.Shapes.Rectangle
        $h = $(if ($max -gt 0) { [math]::Max(1.5, 40.0 * $r.Series[$i] / $max) } else { 1.5 })
        $rect.Width = $w; $rect.Height = $h; $rect.RadiusX = 1; $rect.RadiusY = 1
        $rect.Fill = Get-Brush $(if ($i -eq $n - 1) { $Colors.accent } else { $Colors.accentDim })
        [System.Windows.Controls.Canvas]::SetLeft($rect, $i * ($w + $gap))
        [System.Windows.Controls.Canvas]::SetTop($rect, 42 - $h)
        $at = $r.SlotStart[$i]
        $label = switch ($r.Unit) { 'hour' { $at.ToString('ddd h tt', $inv) } 'day' { $at.ToString('ddd MMM d', $inv) } default { $at.ToString('MMMM yyyy', $inv) } }
        $rect.ToolTip = "$label  ·  $(Format-Tok $r.Series[$i]) tokens  ·  $($r.SeriesReq[$i]) req"
        [void]$UI.RpChart.Children.Add($rect)
    }
    switch ($r.Unit) {
        'hour'  { $UI.RpChartLbl.Text = 'BY HOUR'; $UI.RpAxL.Text = $r.From.ToString('h tt', $inv).ToLower(); $UI.RpAxR.Text = 'now' }
        'day'   { $UI.RpChartLbl.Text = 'BY DAY'; $UI.RpAxL.Text = $r.From.ToString('MMM d', $inv); $UI.RpAxR.Text = 'today' }
        default { $UI.RpChartLbl.Text = 'BY MONTH'; $UI.RpAxL.Text = $r.From.ToString('MMM', $inv); $UI.RpAxR.Text = $r.SlotStart[$n - 1].ToString('MMM', $inv) }
    }
}

function Update-Report {
    if ($UI.ReportPanel.Visibility -ne 'Visible' -or -not $script:Reader) { return }
    $p = Get-ReportPeriod
    $r = $script:Reader.GetReport($p)
    $t = $r.Total
    $key = "$p|$($t.Tokens)|$($t.Req)|$($t.Err)|$($r.Prev.Tokens)|$($r.To.Ticks)"
    if ($key -eq $script:RpKey) { return }
    $script:RpKey = $key
    $script:LastReport = $r
    Update-TabStyles

    $UI.RpRange.Text = Get-ReportRange $r
    $UI.RpBig.Text = Format-Tok $t.Tokens

    # change against the period before
    $prev = $r.Prev
    if ($prev.Tokens -gt 0) {
        $ch = 100.0 * ($t.Tokens - $prev.Tokens) / $prev.Tokens
        $UI.RpDeltaPct.Text = '{0} {1:0}%' -f $(if ($ch -ge 0) { [char]0x25B2 } else { [char]0x25BC }), [math]::Abs($ch)
        $UI.RpDeltaPct.Foreground = Get-Brush $(if ($ch -ge 0) { $Colors.ok } else { $Colors.crit })
        $UI.RpDeltaText.Text = "vs $($PeriodVs[$p])"
        $UI.RpDeltaPct.Visibility = 'Visible'
    } else {
        $UI.RpDeltaPct.Visibility = 'Collapsed'
        $UI.RpDeltaText.Text = $(if ($p -eq 'today') { 'nothing by this hour yesterday' } else { "nothing in the $($PeriodVs[$p])" })
    }
    $UI.RpDelta.ToolTip = "Before: $(Format-Tok $prev.Tokens) tokens  ·  $($prev.Req) requests`n" +
                          "$($r.PrevFrom.ToString('g')) – $($r.PrevTo.ToString('g'))"

    Set-ReportChart $r

    $UI.RpStats.Children.Clear()
    [void]$UI.RpStats.Children.Add((New-Stat (Format-Tok $t.Pp) 'prompt tokens' $Colors.text2 "$($t.Pp.ToString('N0')) prompt tokens processed"))
    [void]$UI.RpStats.Children.Add((New-Stat (Format-Tok $t.Tg) 'generated tokens' $Colors.text2 "$($t.Tg.ToString('N0')) tokens generated"))
    [void]$UI.RpStats.Children.Add((New-Stat $t.Req.ToString('N0') 'requests'))
    [void]$UI.RpStats.Children.Add((New-Stat ('{0:0}%' -f $t.CachePct) 'prompt cached' $Colors.text2 "$(Format-Tok $t.Cached) prompt tokens reused from the cache"))
    [void]$UI.RpStats.Children.Add((New-Stat ('{0:0.0} tok/s' -f $t.GenTps) 'avg gen speed'))
    [void]$UI.RpStats.Children.Add((New-Stat ('{0:N0} tok/s' -f $t.PromptTps) 'avg prompt speed'))
    [void]$UI.RpStats.Children.Add((New-Stat (Format-Duration ($t.PpMs + $t.TgMs)) 'time working' $Colors.text2 'Time spent reading prompts and generating'))
    [void]$UI.RpStats.Children.Add((New-Stat $t.Err.ToString('N0') 'errors' $(if ($t.Err -gt 0) { $Colors.crit } else { $Colors.text2 })))

    $UI.RpModels.Children.Clear()
    $rows = @($r.Models | Select-Object -First ([math]::Max(3, [int]$script:Cfg.topModels + 2)))
    if (-not $rows.Count) { [void]$UI.RpModels.Children.Add((New-Row 'nothing in this period' '' $Colors.muted)) }
    $top = $(if ($rows.Count) { [math]::Max(1, $rows[0].Tokens) } else { 1 })
    foreach ($m in $rows) {
        $tip = "$($m.Model)`n$($m.Req) requests  ·  $(Format-Tok $m.Pp) prompt  ·  $(Format-Tok $m.Tg) generated`ngen {0:0.0} tok/s  ·  prompt {1:0} tok/s  ·  {2:0}% cached" -f $m.GenTps, $m.PromptTps, $m.CachePct
        [void]$UI.RpModels.Children.Add((New-Row (Get-ShortModel $m.Model) ('{0}  ·  {1} req' -f (Format-Tok $m.Tokens), $m.Req) $Colors.text2 $tip))
        $track = New-Object System.Windows.Controls.Border
        $track.Height = 3; $track.CornerRadius = 1.5; $track.Margin = '0,1,0,5'
        Set-Res $track ([System.Windows.Controls.Border]::BackgroundProperty) 'Track'
        $fill = New-Object System.Windows.Controls.Border
        $fill.HorizontalAlignment = 'Left'; $fill.CornerRadius = 1.5; $fill.Background = Get-Brush $Colors.accent
        $fill.Width = [math]::Max(1.0, $BarWidth * $m.Tokens / $top)
        $track.Child = $fill
        [void]$UI.RpModels.Children.Add($track)
    }
}
