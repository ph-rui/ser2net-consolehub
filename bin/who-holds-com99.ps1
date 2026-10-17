# who-holds-com99.ps1 -- ELEVATED (UAC): handle64 full dump
$ErrorActionPreference = 'Continue'
$root   = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$out = Join-Path $logDir 'handle-com99.txt'
# locate handle64.exe: next to this script, in Temp\opencode, or on PATH
$h = @(
    (Join-Path $PSScriptRoot 'handle64.exe'),
    (Join-Path ([IO.Path]::GetTempPath()) 'opencode\handle64.exe')
) | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $h) { $h = (Get-Command handle64.exe -ErrorAction SilentlyContinue).Source }
if (-not $h) {
    Write-Host 'handle64.exe not found - copy Sysinternals handle64.exe next to this script or into Temp\opencode\'
    exit 1
}
'=== handle64 result ===' | Out-File $out -Encoding utf8
& $h -accepteula -nobanner * 2>&1 | Out-File $out -Append -Encoding utf8
'written to ' + $out