# --------------------------------------------------------------- sources ----
# Where LM Studio keeps its server logs. A standard install writes to
# %USERPROFILE%\.lmstudio\server-logs; some setups write to
# %USERPROFILE%\.lmstudio\apps\<app>\server-logs instead (for example "bionic"), and a
# machine can have both. Each folder is read with its own state, and the window follows
# whichever server wrote last.

# LM Studio's home: ~\.lmstudio, unless ~\.lmstudio-home-pointer names another folder.
function Get-LmHome {
    $pointer = Join-Path $env:USERPROFILE '.lmstudio-home-pointer'
    if (Test-Path $pointer) {
        try {
            $p = ([System.IO.File]::ReadAllText($pointer)).Trim()
            if ($p -and (Test-Path $p)) { return $p.TrimEnd('\', '/') }
        } catch {}
    }
    return Join-Path $env:USERPROFILE '.lmstudio'
}

function ConvertTo-SourceName([string]$s) {
    $n = ($s -replace '[|\t\r\n]', '').Trim()
    if (-not $n) { $n = 'logs' }
    return $n
}

# @(@{ name; dir }) - every folder to read, no duplicates.
function Find-LogSources {
    $found = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param([string]$name, [string]$dir)
        $dir = [Environment]::ExpandEnvironmentVariables($dir).TrimEnd('\', '/')
        $key = $dir.ToLowerInvariant()
        if (-not $dir -or $seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $name = ConvertTo-SourceName $name
        $base = $name; $i = 2
        while (@($found | Where-Object { $_.name -eq $name }).Count) { $name = "$base$i"; $i++ }
        [void]$found.Add(@{ name = $name; dir = $dir })
    }
    if ($script:Cfg.autoDetect) {
        $home_ = Get-LmHome
        & $add 'main' (Join-Path $home_ 'server-logs')
        $apps = Join-Path $home_ 'apps'
        if (Test-Path $apps) {
            foreach ($d in Get-ChildItem $apps -Directory -ErrorAction SilentlyContinue) {
                $logs = Join-Path $d.FullName 'server-logs'
                if (Test-Path $logs) { & $add $d.Name $logs }
            }
        }
    }
    foreach ($d in @($script:Cfg.logDirs)) {
        if (-not $d) { continue }
        # named after the folder above "server-logs" (or the folder itself)
        $p = ([string]$d).TrimEnd('\', '/')
        $name = Split-Path $p -Leaf
        if ($name -eq 'server-logs') { $name = Split-Path (Split-Path $p -Parent) -Leaf }
        & $add $name $p
    }
    return $found.ToArray()
}

# ----------------------------------------------------------------- reader ----

$script:Reader      = $null
$script:ReaderKey   = ''
$script:SourcesAt   = [datetime]::MinValue

function Start-Reader {
    $src = @(Find-LogSources)
    $script:ReaderKey = (@($src | ForEach-Object { "$($_.name)=$($_.dir)" }) -join ';')
    $names = [string[]]@($src | ForEach-Object { $_.name })
    $dirs  = [string[]]@($src | ForEach-Object { $_.dir })
    $script:Reader = [LocalTokens.LogMonitor]::new($names, $dirs, $script:CachePath, [int]$script:Cfg.backfillDays)
    $script:Reader.Start()
    $script:SourcesAt = Get-Date
}

function Stop-Reader {
    if ($script:Reader) { try { $script:Reader.Stop() } catch {}; $script:Reader = $null }
}

# A new LM Studio log folder (or a changed logDirs) - start the reader over with it.
# Checked every few minutes: cheap, and a new app folder is rare.
function Sync-Sources([switch]$Now) {
    if (-not $Now -and ([datetime]::Now - $script:SourcesAt).TotalMinutes -lt 5) { return }
    $script:SourcesAt = Get-Date
    $key = (@(@(Find-LogSources) | ForEach-Object { "$($_.name)=$($_.dir)" }) -join ';')
    if ($key -ne $script:ReaderKey) { Stop-Reader; Start-Reader }
}

# Forget everything read so far and read all logs again.
function Reset-Reader {
    Stop-Reader
    try { Remove-Item $script:CachePath -Force -ErrorAction Stop } catch {}
    Start-Reader
}

# -------------------------------------------------------------------- api ----
# LM Studio's local REST API: what is loaded right now.

$script:ApiTask   = $null
$script:ApiTry    = [datetime]::MinValue
$script:ApiAt     = [datetime]::MinValue
$script:ApiOk     = $false
$script:Loaded    = @()      # @(@{ id; type; quant; ctx })

function Start-ApiProbe {
    if ($script:ApiTask -and -not $script:ApiTask.IsCompleted) { return }
    $script:ApiTry = Get-Date
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        if ($script:Cfg.apiToken) { $wc.Headers.Add('Authorization', "Bearer $($script:Cfg.apiToken)") }
        $url = ([string]$script:Cfg.apiUrl).TrimEnd('/') + '/api/v0/models'
        $script:ApiTask = $wc.DownloadStringTaskAsync($url)
    } catch {
        $script:ApiTask = $null
    }
}

function Collect-ApiProbe {
    if (-not $script:ApiTask -or -not $script:ApiTask.IsCompleted) { return }
    $t = $script:ApiTask
    $script:ApiTask = $null
    if ($t.Status -ne 'RanToCompletion') { $script:ApiOk = $false; return }
    try { $j = $t.Result | ConvertFrom-Json } catch { $script:ApiOk = $false; return }
    $script:Loaded = @($j.data | Where-Object { $_ -and $_.state -eq 'loaded' } | ForEach-Object {
        @{ id = [string]$_.id; type = [string]$_.type; quant = [string]$_.quantization
           ctx = $(if ($_.loaded_context_length) { [long]$_.loaded_context_length } else { [long]$_.max_context_length }) }
    })
    $script:ApiOk = $true
    $script:ApiAt = Get-Date
}

function Test-ApiFresh {
    return $script:ApiOk -and ([datetime]::Now - $script:ApiAt).TotalSeconds -lt (3 * [double]$script:Cfg.apiSeconds + 10)
}
