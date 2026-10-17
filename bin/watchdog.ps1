<#
    watchdog.ps1 - bring the autostart loop back if it dies.

    Why this exists
    ---------------
    The autostart loop was observed dying with NO entry in autostart.log and no
    crash event anywhere: the process was simply gone, its children (ser2net
    and query-server) left orphaned but still running.  That state is worse
    than an obvious outage, because it LOOKS healthy - query-server keeps
    answering `console.sh --list`, so the bridge appears alive, while ser2net
    serves a config in which every device is `enable: off` and every real
    connection is refused.  It stayed that way for a week because nothing was
    scheduled to notice.

    Why it is its own task, and not a timer on the loop's task
    ----------------------------------------------------------
    A relaunch timer attached to the loop's OWN task (a repetition on its boot
    trigger) is gated on that task's state - exactly the thing that can be
    wrong when the loop has just been killed, which is the only situation this
    is meant to recover from.  Measured: a repetition on the boot trigger with
    a confirmed-dead loop did not produce a new instance within 165 s.

    This is a separate task on a plain repeating schedule (a MINUTE trigger,
    which is how Task Scheduler implements every "repeat every N minutes" task
    there is), and it relaunches with `schtasks /Run`, which starts an instance
    regardless of what the main task believes about its own state - that call
    has worked in every situation encountered here.

    What it does
    ------------
    Nothing but look.  If a loop is running, exit immediately; if not, start
    the boot task and write one line saying so.  It never touches ser2net,
    never opens a COM port, never renders - the loop does all of that itself
    when it comes back.

    Cost: one extra powershell process every few minutes, alive for well under
    a second when there is nothing to do, and silent in that case.

    Installed/checked by harden-boot-task.ps1 (run it as Administrator).
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $TaskName = 'ser2net-consolehub',
    [string] $LogPath  # default: <repo>/logs/watchdog.log
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $LogPath) { $LogPath = Join-Path $Root 'logs\watchdog.log' }

# Written to only when something actually happens, so the file stays a record
# of recoveries rather than hundreds of "nothing was wrong" lines a day.  If it
# never grows, the loop has never died.
function Say {
    param([string] $m)
    $dir = Split-Path $LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Add-Content -Path $LogPath -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

# This runs as SYSTEM, so reading another SYSTEM process's CommandLine is
# allowed - which is the whole reason it can tell a live loop from a dead one
# without touching the network or a COM port.
$loops = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -match 'autostart\.ps1' })

# The common case, by far: a loop is alive, so do nothing and say nothing.
if ($loops.Count -gt 0) { exit 0 }

Say ('watchdog: no autostart loop found - starting "{0}"' -f $TaskName)
$out = schtasks /Run /TN $TaskName 2>&1
$code = $LASTEXITCODE
Say ('watchdog: schtasks /Run exit={0} {1}' -f $code, ((($out | ForEach-Object { "$_" }) -join ' ').Trim()))
exit $code
