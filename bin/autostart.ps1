<#
    autostart.ps1 - entry point for the boot task "ser2net-consolehub".

    Runs at BOOT as LOCAL SYSTEM (no login required) via a scheduled task:
        \ser2net-consolehub   MSFT_TaskBootTrigger   NT AUTHORITY\SYSTEM

    Two things this handles that a bare `serial-hub.ps1 start` does not:

      1. USB devices are often not enumerated yet at boot, so it waits
         for any USB-serial (CH344 quad or standalone adapters) to appear
         before rendering.
      2. It re-runs `reconcile` every 15 s. `reconcile` is a no-op unless
         the device/COM mapping really changed, so it will NOT interrupt a
         live console session - it only restarts ser2net when a board was
         replugged onto a different COM number.

    Install (once, administrator, UAC prompt):
      powershell -ExecutionPolicy Bypass -File "C:\ser2net\bin\install-boot-task.ps1"
    (paths are relative to this file - works from any install directory)

    Remove later (administrator):
      schtasks /Delete /TN ser2net-consolehub /F
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [int] $WaitForUsbSeconds = 120,
    [int] $PollSeconds = 15,
    [switch] $NoQueryServer
)

$ErrorActionPreference = 'Continue'
$Root     = Split-Path -Parent $PSScriptRoot
$Hub      = Join-Path $PSScriptRoot 'serial-hub.ps1'
$Query    = Join-Path $PSScriptRoot 'query-server.ps1'
$BootLog  = Join-Path $Root 'logs\autostart.log'
$RequestPath = Join-Path $Root 'restart.request'

if (-not (Test-Path (Split-Path $BootLog))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $BootLog) | Out-Null
}

function Say {
    param([string] $m)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $BootLog -Value $line
}

Say 'autostart: entered'

# ---- single instance --------------------------------------------------------
# The boot task relaunches this script on a timer so a KILLED loop comes back
# by itself (it was observed dying for no logged reason and taking the whole
# bridge down silently for a week).  That only works if a second copy exits
# instead of fighting the first: two loops would both own the reconcile timer
# and the query-server watchdog, and could restart ser2net out from under a
# live console session.
#
# A named mutex needs no lock file to clean up - the kernel drops it the
# instant this process dies for any reason, so a crash can never leave a
# stale lock behind that would stop the relaunch forever.
$InstanceMutex = $null
try {
    $InstanceMutex = New-Object System.Threading.Mutex($false, 'Global\ser2net-consolehub-autostart')
    if (-not $InstanceMutex.WaitOne(0)) {
        Say 'autostart: another instance is alive - exiting (relaunch timer, not a failure)'
        $InstanceMutex.Dispose()
        exit 0
    }
} catch {
    # Running without the guard is better than refusing to start: a duplicate
    # loop is annoying, a bridge that never comes back is not usable.
    Say "autostart: single-instance guard unavailable ($($_.Exception.Message)) - continuing without it"
    $InstanceMutex = $null
}

# ---- 1. wait for USB enumeration -------------------------------------------
$deadline = (Get-Date).AddSeconds($WaitForUsbSeconds)
$seen = $false
while ((Get-Date) -lt $deadline) {
    $n = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '\(COM\d+\)' -and $_.DeviceID -like 'USB\*' }).Count
    if ($n -gt 0) { $seen = $true; Say "autostart: USB-serial present ($n ports)"; break }
    Start-Sleep -Seconds 3
}
if (-not $seen) {
    Say "autostart: no USB-serial after $WaitForUsbSeconds s - starting anyway (devices render as enable: off)"
}

# ---- 2. initial start -------------------------------------------------------
try {
    & $Hub start *>> $BootLog
    Say 'autostart: start done'
} catch {
    Say "autostart: start failed: $($_.Exception.Message)"
}

# ---- 2a. live device-table query server -------------------------------------
# The Linux side pulls the CURRENT device list from here, every run, so an
# unplugged adapter disappears (and a new one appears) within milliseconds
# instead of whenever somebody remembers to refresh something.
# Independent of ser2net: it only enumerates USB, it never opens a COM port.
$QueryProc = $null
if (-not $NoQueryServer -and (Test-Path $Query)) {
    $qp = 0
    try { $qp = [int] (Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'settings.json') |
                        ConvertFrom-Json).queryPort } catch { }
    # Reap a previous instance so a re-run of this script cannot leave a
    # duplicate listener fighting over the port.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'query-server\.ps1' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Say "autostart: killed stale query-server pid $($_.ProcessId)"
        }
    if ($qp -gt 0) {
        $QueryProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                            '-File', "`"$Query`"") `
            -WindowStyle Hidden -PassThru
        Say "autostart: query-server started (pid $($QueryProc.Id), port $qp)"
    } else {
        Say 'autostart: queryPort is 0 - query server not started'
    }
}

# ---- 2b. (no warm-probes - they do more harm than good) ---------------------
# An earlier design "warmed" the ports with banner probes after start.  That
# was removed: every extra TCP connection occupies ser2net's single-slot
# connection (kickolduser would even drop a live user console), and a bare
# connect + immediate close (the old /dev/tcp preflight, `nc -z`, or a
# fast probe) makes the NEXT connection fail with "Device open failure:
# Permission denied" (ser2net/gensio + WCH driver quirk).  ptybridge.py reads
# the banner itself and auto-reconnects once if it ever sees that failure,
# so the first real connect is self-healing without any probes.

# ---- 3. periodic reconcile --------------------------------------------------
Say "autostart: reconciling every $PollSeconds s (no-op unless device/COM mapping changed)"
while ($true) {
    Start-Sleep -Seconds $PollSeconds
    try {
        # Honor an interactive restart/stop request.  ser2net is owned by this
        # SYSTEM loop, so a plain user shell cannot stop it directly; it drops
        # restart.request ('stop' or 'restart') instead, and we act here.
        if (Test-Path $RequestPath) {
            $act = ((Get-Content $RequestPath -Raw -ErrorAction SilentlyContinue) -replace '\s+', '').Trim()
            Remove-Item $RequestPath -Force -ErrorAction SilentlyContinue
            if ($act -eq 'stop') {
                Say 'autostart: stop requested (note: reconcile restarts it if this is a bridge-up environment)'
                & $Hub stop *>> $BootLog
            } else {
                Say 'autostart: restart requested'
                & $Hub stop *>> $BootLog
                & $Hub start *>> $BootLog
                Say 'autostart: restart applied'
            }
        }
    } catch {
        Say "autostart: marker handling error: $($_.Exception.Message)"
    }
    try {
        $out = & $Hub reconcile 2>&1
        # Match on the restart line, not on one cause: reconcile restarts for
        # more than one reason (a remapped COM port, and - since the config can
        # now be re-rendered by hand - a yaml newer than the running ser2net).
        # Matching only the mapping message is why a real config-driven restart
        # used to leave no trace in this log at all.
        if ($out -match 'restarting to pick it up') {
            Say "autostart: $((($out | Out-String) -replace '\s+', ' ').Trim())"
            # ser2net got restarted (ports closed again).  Deliberately no
            # warm probe: restarts do NOT poison the next connect, and the
            # probe would only eat the single connection slot and could kick
            # a live user session.  ptybridge.py self-heals any transient.
        }
    } catch {
        Say "autostart: reconcile error: $($_.Exception.Message)"
    }

    # ---- query-server watchdog ---------------------------------------------
    # The query server is the Linux side's ONLY source of the device table.  If
    # it dies, every `console.sh` on every client fails outright - there is no
    # snapshot left to fall back on - so it is restarted in place.  Cheap
    # liveness check on the child we started; no port probing, since HasExited
    # avoids touching the network entirely.
    if ($QueryProc -and $qp -gt 0 -and -not $NoQueryServer) {
        $alive = $true
        try { $alive = -not $QueryProc.HasExited } catch { $alive = $false }
        if (-not $alive) {
            Say "autostart: query-server died (exit $($QueryProc.ExitCode)) - restarting"
            try {
                $QueryProc = Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                                    '-File', "`"$Query`"") `
                    -WindowStyle Hidden -PassThru
                Say "autostart: query-server restarted (pid $($QueryProc.Id))"
            } catch {
                Say "autostart: query-server restart failed: $($_.Exception.Message)"
            }
        }
    }
}