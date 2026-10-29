<#
  LocalTokens tests. Runs in Windows PowerShell 5.1 and PowerShell 7 (also on Linux).

    powershell -ExecutionPolicy Bypass -File tests\Test-LocalTokens.ps1

  1. Every .ps1 file parses.
  2. The log reader compiles and reads the sample logs in tests\fixtures to the numbers
     worked out by hand below (both log folders, a request split across two files,
     a model switch, an error line, a log line quoted inside a prompt).
  3. Its cache reloads to the same numbers, and the CSV export has the expected rows.
  4. On Windows: window.xaml loads.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = 0
function Check([string]$what, $got, $want) {
    if ("$got" -eq "$want") { Write-Host "  ok    $what = $got" }
    else { Write-Host "  FAIL  $what = $got (expected $want)" -ForegroundColor Red; $script:failed++ }
}

Write-Host 'Parsing scripts'
foreach ($f in Get-ChildItem $root -Recurse -Filter *.ps1) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    Check $f.Name $errs.Count 0
}

Write-Host 'Compiling the log reader'
if (-not ('LocalTokens.LogMonitor' -as [type])) {
    Add-Type -Path (Join-Path $root 'src\LogReader.cs')
}

$fx = Join-Path $PSScriptRoot 'fixtures'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("localtokens-test-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp)
$cache = Join-Path $tmp 'cache.txt'

function Read-Fixtures {
    $m = [LocalTokens.LogMonitor]::new([string[]]@('main', 'bionic'),
        [string[]]@((Join-Path $fx 'main'), (Join-Path $fx 'bionic')), $cache, 0)
    $m.PollMs = 200
    $m.Start()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $m.GetSnapshot($true).CaughtUp -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
    return , $m
}

try {
    foreach ($pass in 'fresh', 'from cache') {
        Write-Host "Reading the sample logs ($pass)"
        $mon = Read-Fixtures
        $s = $mon.GetSnapshot($true)
        Check 'caught up'           $s.CaughtUp $true
        Check 'error'               "$($s.Error)" ''
        Check 'requests'            $s.AllTime.Req 4
        Check 'prompt tokens'       $s.AllTime.Pp 3800
        Check 'generated tokens'    $s.AllTime.Tg 430
        Check 'cached prompt'       $s.AllTime.Cached 4500
        Check 'errors'              $s.AllTime.Err 1
        Check 'active folder'       $s.ActiveSource 'bionic'
        Check 'session reason'      $s.SessionReason 'switch'
        Check 'session model'       $s.SessionModel 'qwen/qwen3.5-9b'
        Check 'session requests'    $s.Session.Req 1
        Check 'session tokens'      $s.Session.Tokens 330
        Check 'session start'       $s.SessionStart.ToString('yyyy-MM-dd HH:mm:ss') '2026-07-02 11:30:02'
        Check 'last model'          $s.Last.Model 'qwen/qwen3.5-9b'
        Check 'last context'        $s.Last.Ctx 2329
        Check 'context slot'        $s.CtxSlot 65536
        Check 'main requests'       (@($s.Sources | Where-Object { $_.Name -eq 'main' })[0].Requests) 2
        Check 'bionic requests'     (@($s.Sources | Where-Object { $_.Name -eq 'bionic' })[0].Requests) 2
        $srv = $mon.GetSnapshot($false)
        Check 'server-mode requests' $srv.Session.Req 2
        Check 'server-mode tokens'   $srv.Session.Tokens 2530
        Check 'server-mode start'    $srv.SessionStart.ToString('yyyy-MM-dd HH:mm:ss') '2026-07-02 10:00:00'
        $glm = @($srv.SessionModels | Where-Object { $_.Model -eq 'zai-org/glm-4.7-flash' })[0]
        Check 'glm gen speed'        ('{0:0.0}' -f $glm.GenTps) '20.0'
        Check 'glm prompt speed'     ('{0:0.0}' -f $glm.PromptTps) '250.0'
        $csv = Join-Path $tmp 'export.csv'
        Check 'csv rows'             $mon.ExportCsv($csv) 3
        $rows = Import-Csv $csv
        Check 'csv qwen 07-01 requests' (@($rows | Where-Object { $_.date -eq '2026-07-01' })[0].requests) 2
        Check 'csv total tokens'     (($rows | Measure-Object total_tokens -Sum).Sum) 4230
        $mon.Stop()
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Checking themes'
# theme.ps1 only defines data and functions at load; the WPF parts run in Set-Theme.
. (Join-Path $root 'src\lib\theme.ps1')
foreach ($id in $Themes.Keys) {
    $t = $Themes[$id]
    $bad = @($t.Keys | Where-Object { $_ -notin 'name', 'pattern' -and $t[$_] -notmatch '^#[0-9A-Fa-f]{8}$' })
    Check "theme $id colours" $bad.Count 0
    if ($t.pattern) { Check "theme $id pattern" $Patterns.ContainsKey($t.pattern) $true }
    $unknown = @($t.Keys | Where-Object { $_ -notin 'name', 'pattern' -and -not $ThemeBase.Contains($_) })
    Check "theme $id keys" $unknown.Count 0
}

# WPF needs a single-threaded apartment (Windows PowerShell 5.1 has one by default).
if ($env:OS -eq 'Windows_NT' -and [System.Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
    Write-Host 'Loading window.xaml'
    Add-Type -AssemblyName PresentationFramework
    [xml]$x = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'src\window.xaml')
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    foreach ($n in 'Root', 'Pattern', 'Big', 'Status', 'GenBar', 'CtxBar', 'Details', 'Hourly', 'Totals', 'Models', 'LastReq', 'LoadedList', 'SourceList') {
        Check "element $n" ($null -ne $w.FindName($n)) $true
    }
}

if ($failed) { Write-Host "$failed check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
