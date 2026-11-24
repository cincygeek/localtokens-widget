# ------------------------------------------------------------------ tray ----
# The tray icon shows the current generation speed; its menu holds the settings.

Add-Type -Namespace LocalTokensWin32 -Name Icons -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(System.IntPtr hIcon);
'@

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text    = 'LocalTokens'
$notify.Visible = $true
$script:IconHandle = [IntPtr]::Zero
$script:IconKey    = ''

function Set-TrayIcon([string]$text, [System.Drawing.Color]$color) {
    $key = "$text|$($color.ToArgb())"
    if ($key -eq $script:IconKey) { return }
    $script:IconKey = $key
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush $color
        $g.FillEllipse($brush, 0, 0, 31, 31)
        $brush.Dispose()
        $size = $(if ($text.Length -ge 3) { 13 } else { 17 })
        $font = New-Object System.Drawing.Font 'Segoe UI', $size, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $g.DrawString($text, $font, [System.Drawing.Brushes]::Black, (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $fmt)
        $font.Dispose(); $fmt.Dispose()
    } finally { $g.Dispose() }
    $h = $bmp.GetHicon()
    $notify.Icon = [System.Drawing.Icon]::FromHandle($h)
    if ($script:IconHandle -ne [IntPtr]::Zero) { [void][LocalTokensWin32.Icons]::DestroyIcon($script:IconHandle) }
    $script:IconHandle = $h
    $bmp.Dispose()
}

function Update-Tray($s, [double]$tps, [bool]$offline) {
    if ($offline) {
        Set-TrayIcon '--' ([System.Drawing.Color]::FromArgb(107, 114, 128))
    } else {
        $txt = $(if ($tps -ge 999) { '999' } elseif ($tps -gt 0) { '{0:0}' -f $tps } else { '0' })
        $a = [System.Windows.Media.ColorConverter]::ConvertFromString($Colors.accent)
        $c = $(switch ($s.LiveKind) {
            'gen'    { [System.Drawing.Color]::FromArgb($a.R, $a.G, $a.B) }
            'prompt' { [System.Drawing.Color]::FromArgb(251, 191, 36) }
            default  { [System.Drawing.Color]::FromArgb(161, 161, 170) }
        })
        Set-TrayIcon $txt $c
    }
    # NotifyIcon.Text is limited to 63 characters.
    $tip = "LocalTokens  ·  $($UI.Status.Text)`nSession $(Format-Tok $s.Session.Tokens)  ·  Today $(Format-Tok $s.Today.Tokens)"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $notify.Text = $tip
}

# ------------------------------------------------------------------ menu ----

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miTitle = $menu.Items.Add("LocalTokens v$AppVersion"); $miTitle.Enabled = $false
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miShow = $menu.Items.Add('Show / hide window')
$miShow.add_Click({ Switch-Window })

$miDetails = $menu.Items.Add('Details')
$miDetails.add_Click({ Set-Details (-not [bool]$script:Cfg.details) })

$miTop = $menu.Items.Add('Always on top')
$miTop.add_Click({ $script:Cfg.topmost = -not [bool]$script:Cfg.topmost; Save-Config; Apply-Window })

$miSession = New-Object System.Windows.Forms.ToolStripMenuItem 'Session counts from'
$miSesModel = $miSession.DropDownItems.Add('Last model load or switch')
$miSesServer = $miSession.DropDownItems.Add('Last server start')
$miSesModel.add_Click({ $script:Cfg.sessionMode = 'model'; Save-Config; Update-View })
$miSesServer.add_Click({ $script:Cfg.sessionMode = 'server'; Save-Config; Update-View })
[void]$menu.Items.Add($miSession)

$miTheme = New-Object System.Windows.Forms.ToolStripMenuItem 'Theme'
$it = $miTheme.DropDownItems.Add('Auto (Halloween in October)'); $it.Tag = 'auto'
[void]$miTheme.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
foreach ($k in $Themes.Keys) { $it = $miTheme.DropDownItems.Add($Themes[$k].name); $it.Tag = $k }
foreach ($it in $miTheme.DropDownItems) {
    if ($it -is [System.Windows.Forms.ToolStripMenuItem]) {
        $it.add_Click({ param($s, $e) $script:Cfg.theme = [string]$s.Tag; Save-Config; Set-Theme; Update-View })
    }
}
[void]$menu.Items.Add($miTheme)

$miSize = New-Object System.Windows.Forms.ToolStripMenuItem 'Size'
foreach ($k in 1.0, 1.25, 1.5, 1.75, 2.0) {
    $it = $miSize.DropDownItems.Add(('{0:0}%' -f ($k * 100)))
    $it.Tag = $k
    $it.add_Click({ param($s, $e) $script:Cfg.scale = [double]$s.Tag; Save-Config; Apply-Window })
}
[void]$menu.Items.Add($miSize)

$miStartup = $menu.Items.Add('Start with Windows')
$miStartup.add_Click({ Set-StartWithWindows (-not (Test-StartWithWindows)) })

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miExport = $menu.Items.Add('Export stats to CSV...')
$miExport.add_Click({ Export-Stats })

$miLogs = $menu.Items.Add('Open LM Studio log folder')
$miLogs.add_Click({
    $snap = $script:LastSnap
    $dir = $null
    if ($snap) { $dir = @($snap.Sources | Where-Object { $_.Name -eq $snap.ActiveSource -and $_.Exists } | ForEach-Object { $_.Dir })[0] }
    if (-not $dir) { $dir = Join-Path (Get-LmHome) 'server-logs' }
    if (Test-Path $dir) { Start-Process explorer.exe $dir }
})

$miConfig = $menu.Items.Add('Edit settings file')
$miConfig.add_Click({ Start-Process notepad.exe $script:ConfigPath })

$miReread = $menu.Items.Add('Re-read all logs')
$miReread.add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Forget the saved totals and read every LM Studio log again?`nThis can take a minute or two.",
        'LocalTokens', 'OKCancel', 'Question')
    if ($r -eq 'OK') { Reset-Reader; Update-View }
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = $menu.Items.Add('Exit')
$miExit.add_Click({ Stop-App })

# Check marks follow the settings each time the menu opens.
$menu.add_Opening({
    $miDetails.Checked   = [bool]$script:Cfg.details
    $miTop.Checked       = [bool]$script:Cfg.topmost
    $miSesModel.Checked  = ([string]$script:Cfg.sessionMode) -ne 'server'
    $miSesServer.Checked = ([string]$script:Cfg.sessionMode) -eq 'server'
    $miStartup.Checked   = Test-StartWithWindows
    $cur = ([string]$script:Cfg.theme).ToLower(); if (-not $cur) { $cur = 'auto' }
    foreach ($it in $miTheme.DropDownItems) { if ($it -is [System.Windows.Forms.ToolStripMenuItem]) { $it.Checked = ([string]$it.Tag -eq $cur) } }
    foreach ($it in $miSize.DropDownItems) { $it.Checked = [math]::Abs([double]$it.Tag - [double]$script:Cfg.scale) -lt 0.01 }
})

$notify.ContextMenuStrip = $menu
$notify.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Switch-Window }
})

# Everything, or with a report only the hours of its period (the Reports tab's link).
function Export-Stats($report = $null) {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = 'Export LocalTokens stats'
    $dlg.Filter = 'CSV file (*.csv)|*.csv'
    $suffix = $(if ($report) { "-$($report.Period)" } else { '' })
    $dlg.FileName = "localtokens-$(Get-Date -Format 'yyyy-MM-dd')$suffix.csv"
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try {
        $n = $(if ($report) { $script:Reader.ExportCsv($dlg.FileName, $report.From, $report.To) }
               else { $script:Reader.ExportCsv($dlg.FileName) })
        $notify.ShowBalloonTip(5000, 'LocalTokens', "Exported $n rows (one per day and model).", 'Info')
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Export failed: $($_.Exception.Message)", 'LocalTokens', 'OK', 'Error')
    }
}

# --------------------------------------------------------- start with Windows ----
# A shortcut in the user's Startup folder: no admin rights, easy to see and remove.

$script:StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'LocalTokens.lnk'

function Test-StartWithWindows { return (Test-Path $script:StartupLink) }

function Set-StartWithWindows([bool]$on) {
    try {
        if ($on) {
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut($script:StartupLink)
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $lnk.Arguments = "`"$(Join-Path $script:AppRoot 'LocalTokens.vbs')`""
            $lnk.WorkingDirectory = $script:AppRoot
            $lnk.Description = 'LocalTokens - LM Studio token stats'
            $lnk.Save()
        } elseif (Test-Path $script:StartupLink) {
            Remove-Item $script:StartupLink -Force
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Could not change the startup shortcut: $($_.Exception.Message)", 'LocalTokens', 'OK', 'Warning')
    }
}
