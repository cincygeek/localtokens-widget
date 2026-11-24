#requires -version 5
<#
  LocalTokens - a small always-on window and tray icon showing how many tokens your
  local LLMs in LM Studio process: this session, today, this week, per model, and how
  fast they run. Everything is read from LM Studio's own server logs and its local API;
  nothing leaves your computer.

  Start it with LocalTokens.vbs (no console window).
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$AppVersion = '0.2.0'
$script:SrcRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AppRoot = Split-Path -Parent $script:SrcRoot

$ErrorActionPreference = 'Stop'
$ConfirmPreference = 'None'

# Started hidden: an error during start would vanish without a trace, so say it.
trap {
    $msg = "$($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)"
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'LocalTokens'
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        "$(Get-Date -Format s)`tstart: $msg" | Out-File (Join-Path $dir 'error.log') -Append -Encoding utf8
    } catch {}
    try { [void][System.Windows.MessageBox]::Show("LocalTokens could not start:`n`n$msg", 'LocalTokens', 'OK', 'Error') } catch {}
    exit 1
}

# One copy per user.
$isNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\LocalTokens', [ref]$isNew)
if (-not $isNew) { exit 0 }

# The log reader is C#: fast enough to read gigabytes of logs on first run.
if (-not ('LocalTokens.LogMonitor' -as [type])) {
    Add-Type -Path (Join-Path $script:SrcRoot 'LogReader.cs')
}

foreach ($m in 'config', 'sources', 'view', 'theme', 'tray') { . (Join-Path $script:SrcRoot "lib\$m.ps1") }

# ---------------------------------------------------------------- window ----

[xml]$xaml = Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot 'window.xaml')
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$UI = @{}
foreach ($n in 'Root', 'Pattern', 'BtnMenu', 'BtnDetails', 'BtnHide', 'BtnExit', 'Dot', 'Status', 'SourceTag', 'Big', 'BigUnit',
               'ModelLine', 'GenLine', 'GenBar', 'CtxLine', 'CtxBar', 'Foot', 'FootRight', 'Details', 'Hourly',
               'HourStart', 'Totals', 'Models', 'LastLbl', 'LastReq', 'LoadedList', 'SourceList', 'ErrLine', 'Stamp',
               'TabLive', 'TabLiveText', 'TabLiveLine', 'TabReports', 'TabReportsText', 'TabReportsLine', 'LivePanel',
               'ReportPanel', 'PeriodBar', 'RpRange', 'RpBig', 'RpDelta', 'RpDeltaPct', 'RpDeltaText', 'RpChartLbl',
               'RpChart', 'RpAxL', 'RpAxR', 'RpStats', 'RpModels', 'RpExport') {
    $UI[$n] = $win.FindName($n)
}

function Apply-Window {
    $k = [math]::Min(4.0, [math]::Max(0.6, [double]$script:Cfg.scale))
    $UI.Root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $k, $k
    $win.Opacity = [math]::Min(1.0, [math]::Max(0.3, [double]$script:Cfg.opacity))
    $win.Topmost = [bool]$script:Cfg.topmost
    Set-Theme
}

function Set-Details([bool]$open) {
    $UI.Details.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
    $UI.BtnDetails.Text = [string][char]$(if ($open) { 0x25B4 } else { 0x25BE })
    $script:DetKey = $null
    if ($script:Cfg.details -ne $open) { $script:Cfg.details = $open; Save-Config }
    Update-View
}

# Live or Reports. The Details button only applies to Live, so it hides on Reports.
function Set-Tab([string]$tab) {
    $rep = $tab -eq 'reports'
    $UI.LivePanel.Visibility   = $(if ($rep) { 'Collapsed' } else { 'Visible' })
    $UI.ReportPanel.Visibility = $(if ($rep) { 'Visible' } else { 'Collapsed' })
    $UI.BtnDetails.Visibility  = $(if ($rep) { 'Collapsed' } else { 'Visible' })
    $tab = $(if ($rep) { 'reports' } else { 'live' })
    if ($script:Cfg.tab -ne $tab) { $script:Cfg.tab = $tab; Save-Config }
    $script:DetKey = $null; $script:RpKey = $null
    Update-TabStyles
    Update-View
}

function Switch-Window {
    if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() | Out-Null }
}

function Save-Position {
    $script:Cfg.left = [math]::Round($win.Left)
    $script:Cfg.top  = [math]::Round($win.Top)
    Save-Config
}

function Stop-App {
    try { Save-Position } catch {}
    try { Stop-Reader } catch {}
    $notify.Visible = $false
    $notify.Dispose()
    if ($script:IconHandle -ne [IntPtr]::Zero) { [void][LocalTokensWin32.Icons]::DestroyIcon($script:IconHandle) }
    $win.Close()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

# Saved position, if it is still on a screen; otherwise the top right corner.
$win.WindowStartupLocation = 'Manual'
$area = [System.Windows.SystemParameters]::WorkArea
$virt = New-Object System.Windows.Rect ([System.Windows.SystemParameters]::VirtualScreenLeft), ([System.Windows.SystemParameters]::VirtualScreenTop),
                                        ([System.Windows.SystemParameters]::VirtualScreenWidth), ([System.Windows.SystemParameters]::VirtualScreenHeight)
if ($null -ne $script:Cfg.left -and $null -ne $script:Cfg.top -and
    $virt.Contains((New-Object System.Windows.Point ([double]$script:Cfg.left + 40), ([double]$script:Cfg.top + 20)))) {
    $win.Left = [double]$script:Cfg.left
    $win.Top  = [double]$script:Cfg.top
} else {
    $win.Left = $area.Right - 360
    $win.Top  = $area.Top + 20
}
Apply-Window

# ---------------------------------------------------------------- events ----

$UI.Root.add_MouseLeftButtonDown({
    try { $win.DragMove(); Save-Position } catch {}
})
$UI.BtnDetails.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Set-Details ($UI.Details.Visibility -ne 'Visible') })
$UI.TabLive.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Set-Tab 'live' })
$UI.TabReports.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Set-Tab 'reports' })
$UI.RpExport.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; if ($script:LastReport) { Export-Stats $script:LastReport } })
Initialize-PeriodBar
$UI.BtnHide.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; $win.Hide() })
$UI.BtnExit.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Stop-App })
$UI.BtnMenu.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$UI.BtnMenu.add_MouseLeftButtonUp({
    param($s, $e)
    $e.Handled = $true
    $menu.Show([System.Windows.Forms.Cursor]::Position)
})

# An error in a handler or a tick must not take the app down: write it down and go on.
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    Write-AppLog "ui: $($e.Exception.Message)"
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([math]::Max(1, [double]$script:Cfg.refreshSeconds))
$timer.add_Tick({
    try {
        if (Sync-Config) {
            Apply-Window
            Set-Details ([bool]$script:Cfg.details)
            Set-Tab ([string]$script:Cfg.tab)
            $timer.Interval = [TimeSpan]::FromSeconds([math]::Max(1, [double]$script:Cfg.refreshSeconds))
            Sync-Sources -Now
        } else {
            Sync-Sources
        }
        Collect-ApiProbe
        if (([datetime]::Now - $script:ApiTry).TotalSeconds -ge [double]$script:Cfg.apiSeconds) { Start-ApiProbe }
        Update-View
    } catch {
        Write-AppLog "tick: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
    }
})

# ----------------------------------------------------------------- start ----

Start-Reader
Start-ApiProbe
$script:CfgStamp = (Get-Item $script:ConfigPath).LastWriteTimeUtc
$win.Show()
Set-Details ([bool]$script:Cfg.details)
Set-Tab ([string]$script:Cfg.tab)
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()
