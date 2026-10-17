# fix-autostart-loop.ps1 -- one-time elevated helper
#
# The SYSTEM boot-task autostart loop keeps the version of autostart.ps1 that
# was loaded when it started.  After editing autostart.ps1 (marker protocol),
# the running loop is stale: it ignores restart.request.  This script must run
# ELEVATED (UAC).  It:
#   1. kills stale in-memory autostart loops,
#   2. clears a leftover restart.request marker,
#   3. relaunches the boot task so a fresh SYSTEM loop loads the new code.
#
# Usage (from an unelevated shell):
#   Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $PSScriptRoot 'fix-autostart-loop.ps1')
#
# Log: logs\autostart-reload.log

$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$LogPath = Join-Path $Root 'logs\autostart-reload.log'
$RequestPath = Join-Path $Root 'restart.request'

function L([string] $m) {
    ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) |
        Out-File -FilePath $LogPath -Append -Encoding utf8
}

L '=== elevated autostart reload: begin ==='

# 1. kill stale loops (any powershell whose command line references autostart.ps1)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'autostart\.ps1' } |
    ForEach-Object {
        L "killing stale loop pid $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force
    }

# 2. clear leftover marker
if (Test-Path $RequestPath) {
    Remove-Item $RequestPath -Force
    L 'removed stale restart.request'
} else {
    L 'no stale restart.request'
}

# 3. relaunch the boot task -> fresh SYSTEM loop with current autostart.ps1
L 'running: schtasks /Run /TN ser2net-consolehub'
schtasks /Run /TN ser2net-consolehub 2>&1 | ForEach-Object { L "schtasks: $_" }

L '=== elevated autostart reload: done ==='