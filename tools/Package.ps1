<#
  Builds dist\LocalTokens-<version>.zip: what a user downloads and unzips.

    powershell -ExecutionPolicy Bypass -File tools\Package.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$main = Get-Content -Raw (Join-Path $root 'src\LocalTokens.ps1')
$ver = [regex]::Match($main, "\`$AppVersion\s*=\s*'([^']+)'").Groups[1].Value
if (-not $ver) { throw 'could not find $AppVersion in src\LocalTokens.ps1' }

$dist  = Join-Path $root 'dist'
$stage = Join-Path $dist "LocalTokens-$ver"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
[void](New-Item -ItemType Directory -Path $stage -Force)

foreach ($f in 'LocalTokens.vbs', 'README.md', 'LICENSE', 'CHANGELOG.md') {
    Copy-Item (Join-Path $root $f) $stage
}
Copy-Item (Join-Path $root 'src') (Join-Path $stage 'src') -Recurse

$zip = Join-Path $dist "LocalTokens-$ver.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip
Remove-Item $stage -Recurse -Force
Write-Host "Built $zip"
