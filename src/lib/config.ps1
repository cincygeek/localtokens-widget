# ---------------------------------------------------------------- config ----
# Settings live in %APPDATA%\LocalTokens\config.json and are picked up while the app
# runs. The log cache and the error log live in %LOCALAPPDATA%\LocalTokens: they belong
# to this computer, whose LM Studio logs are its own.

$script:DataDir   = Join-Path $env:APPDATA 'LocalTokens'
$script:CacheDir  = Join-Path $env:LOCALAPPDATA 'LocalTokens'
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:CachePath  = Join-Path $script:CacheDir 'log-cache.txt'
$script:ErrorLog   = Join-Path $script:CacheDir 'error.log'
foreach ($d in $script:DataDir, $script:CacheDir) {
    if (-not (Test-Path $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
}

$DefaultConfig = [ordered]@{
    sessionMode    = 'model'   # what "this session" counts: 'model' - since a model load or switch; 'server' - since the server started
    autoDetect     = $true     # find LM Studio's log folders by itself (server-logs and apps\*\server-logs)
    logDirs        = @()       # more server-logs folders to read, e.g. another LM Studio home
    apiUrl         = 'http://127.0.0.1:1234'  # LM Studio's local server, asked what is loaded
    apiToken       = ''        # only if your LM Studio API requires a token
    apiSeconds     = 30        # how often to ask (LM Studio writes each answer into its log)
    refreshSeconds = 2         # how often the window redraws
    backfillDays   = 0         # first run: read this many days of old logs; 0 - all of them
    speedScale     = 80        # tokens/s that fills the speed bar
    slowTps        = 5         # generation slower than this turns the bar yellow
    topModels      = 3         # rows under MODELS TODAY
    warnPercent    = 60        # context bar turns yellow at this share of the context window
    critPercent    = 85        # ... and red at this one
    theme          = 'auto'    # classic, oled, midnight, mocha, forest, paper, halloween, space, ocean, cyberpunk; auto - Halloween in October, classic otherwise
    accent         = ''        # your own accent colour, e.g. '#FF6B9D'; empty - the theme's
    details        = $false    # the details block is open
    tab            = 'live'    # the open tab: 'live' or 'reports'
    reportPeriod   = '24h'     # Reports tab period: 24h, today, week, month, year
    topmost        = $false    # keep the window above other windows
    opacity        = 1.0
    scale          = 1.25      # size of the whole window
    left           = $null     # window position, saved when you drag it
    top            = $null
}

function Load-Config {
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    if (Test-Path $script:ConfigPath) {
        try {
            $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) {
                if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        } catch {
            Write-AppLog "config.json is unreadable, using defaults: $($_.Exception.Message)"
        }
    }
    return $cfg
}

function Save-Config {
    try {
        [PSCustomObject]$script:Cfg | ConvertTo-Json -Depth 3 | Out-File $script:ConfigPath -Encoding utf8
        $script:CfgStamp = (Get-Item $script:ConfigPath).LastWriteTimeUtc
    } catch {
        Write-AppLog "could not save config.json: $($_.Exception.Message)"
    }
}

# Edits made in config.json by hand apply on the next tick.
$script:CfgStamp = $null
function Sync-Config {
    if (-not (Test-Path $script:ConfigPath)) { return $false }
    $stamp = (Get-Item $script:ConfigPath).LastWriteTimeUtc
    if ($stamp -eq $script:CfgStamp) { return $false }
    $script:CfgStamp = $stamp
    $fresh = Load-Config
    $fresh.left = $script:Cfg.left; $fresh.top = $script:Cfg.top   # the window owns its position
    $script:Cfg = $fresh
    return $true
}

function Write-AppLog([string]$msg) {
    try { "$(Get-Date -Format s)`t$msg" | Out-File $script:ErrorLog -Append -Encoding utf8 } catch {}
}

$script:Cfg = Load-Config
if (-not (Test-Path $script:ConfigPath)) { Save-Config }   # a first file to edit
