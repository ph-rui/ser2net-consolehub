<#
    verify-boot-task.ps1 - check (and if needed repair) the boot-time setup.

    Run this after ANY change under bin\, settings.json or devices.json.  The
    autostart loop holds the version of autostart.ps1 / serial-hub.ps1 that it
    loaded when it started, so editing those files changes nothing until the loop
    is restarted - and the failure is silent: the old code keeps running happily
    while you believe the new code is live.  This script makes that state
    visible and fixes it in one step.

    It checks four things:
      1. the scheduled task exists, runs as SYSTEM, and fires at boot
      2. the autostart loop is actually running (session 0, parented by svchost
         = the Task Scheduler service)
      3. ser2net is running and was started BY that loop
      4. the query server is listening on the configured port

    Then it restarts the loop so freshly edited scripts take effect, and starts
    the task if it was missing.  Everything is idempotent: running it twice in a
    row is harmless.

    Usage (from an unelevated shell - it re-launches itself elevated):
        powershell -ExecutionPolicy Bypass -File C:\ser2net\bin\verify-boot-task.ps1
    Or, if you are already Administrator:
        powershell -ExecutionPolicy Bypass -File C:\ser2net\bin\verify-boot-task.ps1 -Elevated

    Log: logs\verify-boot-task.log
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Elevated,       # set when re-launched as admin (internal)
    [switch] $NoFix,          # report only, change nothing
    [switch] $NoQueryServer,  # the query server is optional; don't require it
    [switch] $SelfHealTest    # kill the loop and prove Task Scheduler relaunches it
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$LogPath = Join-Path $Root 'logs\verify-boot-task.log'
$TaskName = 'ser2net-consolehub'

if (-not (Test-Path (Split-Path $LogPath))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
}

function L {
    param([string] $m)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

function Get-Loops {
    # ,$arr on return: a function that yields a one-element array gets unrolled
    # to a bare object by the pipeline, and then .Count is the OBJECT's count
    # (not 1) - which would silently misread "one loop" as "many" or vice versa.
    $r = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -match 'autostart\.ps1' })
    return ,$r
}

function Kill-Loop {
    # The loop runs as LOCAL SYSTEM, so killing it may need SeDebugPrivilege,
    # which administrators hold but in the DISABLED state.  Stop-Process just
    # fails with access-denied then - and with -ErrorAction SilentlyContinue
    # that failure is invisible, which makes a failed kill indistinguishable
    # from "the self-heal guard did not fire".  That ambiguity already cost a
    # whole test run, so: try Stop-Process, fall back to taskkill (which
    # enables the privilege itself), and always report what actually happened.
    param([int] $Id)
    $how = $null
    try {
        Stop-Process -Id $Id -Force -ErrorAction Stop
        $how = 'Stop-Process'
    } catch {
        $out = taskkill /F /PID $Id 2>&1
        $code = $LASTEXITCODE
        $how = "taskkill exit=$code ($((($out | ForEach-Object { "$_" }) -join ' ').Trim()))"
    }
    Start-Sleep -Milliseconds 1500
    $alive = [bool] (Get-Process -Id $Id -ErrorAction SilentlyContinue)
    [pscustomobject]@{ Method = $how; Killed = (-not $alive) }
}

# ---------------------------------------------------------------- elevation
# Querying a SYSTEM-owned task and reading a SYSTEM process's command line both
# need admin, and a half-checked answer ("task not found") is worse than none.
if (-not $Elevated) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        L 'not elevated - re-launching with -Verb RunAs (accept the UAC prompt)'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated')
        if ($NoFix)        { $argList += '-NoFix' }
        if ($NoQueryServer){ $argList += '-NoQueryServer' }
        if ($SelfHealTest) { $argList += '-SelfHealTest' }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
        return
    }
    L 'running elevated'
} else {
    L '=== elevated verify/repair: begin ==='
}

# ------------------------------------------------------------------ settings
$settings = $null
try {
    $settings = Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'settings.json') | ConvertFrom-Json
} catch {
    L "FAIL: settings.json unreadable - $($_.Exception.Message)"
}
$queryPort = 0
if ($settings -and $settings.PSObject.Properties.Name -contains 'queryPort') {
    $queryPort = [int] $settings.queryPort
}

# ------------------------------------------------------------- 1. the task
L ''
L '-- 1. scheduled task --'
$task = $null
try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
if (-not $task) {
    # schtasks is the fallback: on some boxes Get-ScheduledTask needs rights the
    # task's own ACL denies even to administrators.
    $q = schtasks /query /tn $TaskName /fo LIST 2>&1
    if ($q -and (($q | Out-String) -match 'TaskName|任务名')) { L "task $TaskName exists (schtasks sees it, Get-ScheduledTask does not)" }
    else {
        L "FAIL: task $TaskName is MISSING - the bridge will not survive a reboot"
        if (-not $NoFix) {
            L '  -> creating it'
            # Build the -TR string in a variable first: nesting an escaped double
            # quote inside a double-quoted argument is where this goes wrong,
            # and a malformed /TR produces a task that fails only at boot.
            $auto = Join-Path $PSScriptRoot 'autostart.ps1'
            $tr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $auto + '"'
            & schtasks /Create /TN $TaskName /TR $tr /SC ONSTART /RU SYSTEM /RL HIGHEST /F 2>&1 |
                ForEach-Object { L "     $_" }
        }
    }
} else {
    L "task    : $($task.State)"
    L "principal: $($task.Principal.UserId) / $($task.Principal.LogonType) / $($task.Principal.RunLevel)"
    L "trigger : $(($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', ')"
    L "action  : $(($task.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join '')"
    $tinfo = Get-ScheduledTaskInfo -TaskName $TaskName
    L "last run: $($tinfo.LastRunTime)  result=$($tinfo.LastTaskResult)"
    if ($task.Principal.UserId -notmatch 'SYSTEM') { L "WARN: task does not run as SYSTEM - it will not start before login" }
}

# ------------------------------------------------------- 2. the autostart loop
L ''
L '-- 2. autostart loop --'
$loop = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.CommandLine -match 'autostart\.ps1' })
if ($loop.Count -eq 0) {
    L 'FAIL: no autostart loop running'
    if (-not $NoFix) {
        L '  -> schtasks /Run (the task starts the loop)'
        & schtasks /Run /TN $TaskName 2>&1 | ForEach-Object { L "     $_" }
    }
} else {
    foreach ($p in $loop) { L "loop    : pid=$($p.ProcessId) session=$($p.SessionId)" }
    if ($loop.Count -gt 1) { L "WARN: $($loop.Count) loops running - they will fight over the ports" }
    if (($loop | Where-Object { $_.SessionId -eq 0 }).Count -eq 0) {
        L 'WARN: the loop is not in session 0 - it will stop at logoff'
    }
}

# --------------------------------------------------------------- 3. ser2net
L ''
L '-- 3. ser2net --'
$srv = @(Get-CimInstance Win32_Process -Filter "Name='ser2net.exe'" -ErrorAction SilentlyContinue)
if ($srv.Count -eq 0) {
    L 'ser2net is NOT running'
    if (-not $NoFix) {
        & schtasks /Run /TN $TaskName 2>&1 | ForEach-Object { L "     $_" }
        Start-Sleep -Seconds 5
        $srv = @(Get-CimInstance Win32_Process -Filter "Name='ser2net.exe'" -ErrorAction SilentlyContinue)
        L $(if ($srv.Count) { "  -> now running, pid=$($srv[0].ProcessId)" } else { '  -> still not running' })
    }
} else {
    $p = $srv[0]
    $par = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
    $parName = if ($par) { $par.Name } else { '(gone)' }
    L "ser2net : pid=$($p.ProcessId) session=$($p.SessionId) parent=$parName"
    if ($parName -eq '(gone)') { L 'WARN: orphaned (its parent loop died) - a loop restart will re-own it' }
}

# ---------------------------------------------------------- 4. query server
if (-not $NoQueryServer -and $queryPort -gt 0) {
    L ''
    L "-- 4. query server (port $queryPort) --"
    $l = @(netstat -ano | Select-String 'LISTENING' | Select-String (":" + $queryPort + '\s'))
    if ($l.Count -eq 0) {
        L "NOT listening on $queryPort - the Linux side has no device table at all and will fail"
        if (-not $NoFix) {
            L '  -> restarting the loop, which starts it'
            & schtasks /Run /TN $TaskName 2>&1 | ForEach-Object { L "     $_" }
            Start-Sleep -Seconds 8
            $l = @(netstat -ano | Select-String 'LISTENING' | Select-String (":" + $queryPort + '\s'))
            L $(if ($l.Count) { "  -> now listening: $(($l[0].ToString().Trim()))" } else { '  -> still not listening' })
        }
    } else {
        L "listening: $(($l[0].ToString().Trim()))"
    }
}

# --------------------------------------------------- 5. self-healing settings
# The loop dying is not hypothetical - it happened, with no log entry and no
# crash event, and the bridge stayed silently broken for a week: query-server
# was orphaned but alive (so --list kept answering, which looks healthy) while
# ser2net served a stale config with every device `enable: off`, so every real
# connection was refused.  Nothing restarted the loop, so nothing ever
# re-rendered.  Apply the guard that makes the task relaunch itself.
L ''
L '-- 5. self-healing settings --'
if ($NoFix) {
    L 'NoFix: reporting only'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'harden-boot-task.ps1') -TaskName $TaskName -ReportOnly |
        ForEach-Object { L "  $_" }
} else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'harden-boot-task.ps1') -TaskName $TaskName |
        ForEach-Object { L "  $_" }
    if ($LASTEXITCODE -ne 0) { L "WARN: harden exit=$LASTEXITCODE - some settings did not stick" }
}

# ------------------------------------------------------- restart to pick up edits
L ''
L '-- restart loop so edited scripts take effect --'
if ($NoFix) {
    L 'NoFix: not restarting'
} else {
    # Drop the leftover marker first: a stale 'restart' would make the fresh loop
    # restart ser2net one more time on its first tick, for no reason.
    $req = Join-Path $Root 'restart.request'
    if (Test-Path $req) { Remove-Item $req -Force; L 'removed stale restart.request' }
    L 'stopping stale loops (their in-memory scripts are out of date)'
    foreach ($p in @(Get-Loops)) {
        $r = Kill-Loop -Id ([int] $p.ProcessId)
        L "  pid $($p.ProcessId): $(if ($r.Killed) { 'killed via ' + $r.Method } else { 'STILL ALIVE - ' + $r.Method })"
    }
    Start-Sleep -Seconds 2
    L "schtasks /Run /TN $TaskName"
    & schtasks /Run /TN $TaskName 2>&1 | ForEach-Object { L "  $_" }
    Start-Sleep -Seconds 6
    $new = Get-Loops
    L $(if ($new.Count) { "new loop: pid=$($new[0].ProcessId) - current scripts are live" }
       else { 'WARN: no loop after Run - check the task and logs\autostart.log' })
}

# --------------------------------------------------------- 6. self-heal test
L ''
L '-- 6. self-heal test (kill the loop; expect the task to relaunch it) --'
if (-not $SelfHealTest) {
    L 'skipped - re-run with -SelfHealTest to prove the guard actually works'
} elseif ($NoFix) {
    L 'NoFix: skipping'
} else {
    # A guard nobody has ever watched fail is not a guard.  The loop being
    # killed is exactly the event that took the bridge down for a week, so
    # reproduce it deliberately and confirm something brings the loop back.
    $harden = Join-Path $PSScriptRoot 'harden-boot-task.ps1'
    $WdTaskName = "$TaskName-watchdog"
    $WdLog = Join-Path $Root 'logs\watchdog.log'
    # Shorten both timers for the test so it resolves in about a minute instead
    # of the production schedule, then put them back - the interval you are
    # willing to sit and watch, and the interval you can live with in
    # production, are not the same number.
    $ProdRepeat = 'PT10M'; $TestRepeat = 'PT1M'
    $ProdWd = 3; $TestWd = 1
    L "  timers for test: watchdog every $ProdWd -> $TestWd min, repeat $ProdRepeat -> $TestRepeat"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $harden -TaskName $TaskName `
                 -RepeatEvery $TestRepeat -WatchdogEveryMinutes $TestWd | Out-Null
    # Not silenced without also reporting the exit code: an earlier run silently
    # installed nothing (a CIM property name differs from the XML element name)
    # and the test then "failed" for a reason unrelated to what it was testing.
    if ($LASTEXITCODE -ne 0) { L "  FAIL: harden exit=$LASTEXITCODE - settings not applied, result would be meaningless" }
    else { L '  harden exit=0 - settings applied' }

    # Get-Loops returns its array with `,` so a single result is not unrolled;
    # assign it first and THEN pipe, because piping the function call directly
    # hands Where-Object the whole array as one item, which makes an EMPTY
    # result look like Count=1.  That shape reads as "a loop appeared" when
    # there is nothing at all.
    $alive = @(Get-Loops)
    L "  loops before kill: $(if ($alive.Count) { ($alive | ForEach-Object { $_.ProcessId }) -join ',' } else { 'none' })"
    if (-not $alive.Count) {
        L '  no loop running to kill - starting one first'
        & schtasks /Run /TN $TaskName 2>&1 | ForEach-Object { L "    $_" }
        Start-Sleep -Seconds 10
        $alive = @(Get-Loops)
    }
    if (-not $alive.Count) {
        L '  WARN: could not get a loop up, test not run'
    } else {
        $victim = [int] $alive[0].ProcessId
        L "  killing loop pid $victim"
        $killAt = Get-Date
        $k = Kill-Loop -Id $victim
        L "  kill method: $($k.Method) -> $(if ($k.Killed) { 'confirmed dead' } else { 'CONFIRMED STILL ALIVE' })"
        if (-not $k.Killed) {
            L '  FAIL: could not kill the loop, so nothing was actually tested'
        } else {
            $leftover = @(@(Get-Loops) | Where-Object { $_.ProcessId -ne $victim })
            L "  other loops still around: $(if ($leftover.Count) { ($leftover | ForEach-Object { $_.ProcessId }) -join ',' } else { 'none' })"

            # Log what Task Scheduler itself says while we wait, not just
            # whether a process showed up: "the timer never fired" and "the
            # timer fired but something blocked the new instance" look
            # identical from the outside, and the fix for each is different.
            $wdBefore = $null; $mtBefore = $null
            try { $wdBefore = Get-ScheduledTaskInfo -TaskName $WdTaskName -ErrorAction Stop } catch { }
            try { $mtBefore = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop } catch { }

            $newPid = 0
            $deadline = (Get-Date).AddSeconds(165)
            $nextDiag = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 5
                $now = @(Get-Loops)
                $cands = @($now | Where-Object { $_.ProcessId -ne $victim })
                if ($cands.Count -gt 0) { $newPid = [int] $cands[0].ProcessId; break }
                if ((Get-Date) -ge $nextDiag) {
                    $nextDiag = (Get-Date).AddSeconds(20)
                    $wdNow = $null; $mtNow = $null; $mtState = '?'
                    try { $wdNow = Get-ScheduledTaskInfo -TaskName $WdTaskName -ErrorAction Stop } catch { }
                    try { $mt = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop; $mtState = $mt.State } catch { }
                    try { $mtNow = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop } catch { }
                    L ("  +{0,3}s  loops=none  main={1} lastRun={2} result={3}  watchdog lastRun={4} result={5}" -f `
                       ([int] ((Get-Date) - $killAt).TotalSeconds), $mtState, `
                       $(if ($mtNow) { $mtNow.LastRunTime.ToString('HH:mm:ss') } else { '?' }), `
                       $(if ($mtNow) { $mtNow.LastTaskResult } else { '?' }), `
                       $(if ($wdNow) { $wdNow.LastRunTime.ToString('HH:mm:ss') } else { 'never' }), `
                       $(if ($wdNow) { $wdNow.LastTaskResult } else { '?' }))
                }
            }
            if ($newPid) {
                L "  PASS: relaunched on its own as pid $newPid"
                if ($wdBefore -and (Get-ScheduledTaskInfo -TaskName $WdTaskName).LastRunTime -gt $wdBefore.LastRunTime) {
                    L '        by the WATCHDOG task'
                } elseif ($mtBefore -and (Get-ScheduledTaskInfo -TaskName $TaskName).LastRunTime -gt $mtBefore.LastRunTime) {
                    L '        by the main task (repetition/restart-on-failure fired)'
                }
            } else {
                L '  FAIL: no relaunch within 165 s - self-heal did not work'
            }
            if (Test-Path $WdLog) {
                L '  -- watchdog.log tail --'
                Get-Content $WdLog -Tail 6 | ForEach-Object { L "    $_" }
            } else {
                L '  (no watchdog.log - the watchdog has never had to act)'
            }
        }
    }

    L "  restoring timers: repeat $ProdRepeat, watchdog every $ProdWd min"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $harden -TaskName $TaskName `
                 -RepeatEvery $ProdRepeat -WatchdogEveryMinutes $ProdWd | Out-Null

    # Never leave the bridge down because a test went badly.
    if (-not (@(Get-Loops)).Count) {
        L '  no loop at end of test - restarting it'
        & schtasks /Run /TN $TaskName 2>&1 | ForEach-Object { L "    $_" }
        Start-Sleep -Seconds 10
        $rec = @(Get-Loops)
        L $(if ($rec.Count) { "  recovered: pid=$($rec[0].ProcessId)" } else { '  WARN: still no loop - investigate logs\autostart.log' })
    }
}

L '=== verify/repair: done ==='