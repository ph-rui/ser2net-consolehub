<#
    harden-boot-task.ps1 - make the boot task self-healing.

    Why this exists: the autostart loop was observed dying with NO entry in
    autostart.log and no crash event in the event log - the process was simply
    gone (its children, ser2net and query-server, were left orphaned and still
    running).  Nothing restarted it, so the bridge stayed silently broken for a
    week: query-server kept answering --list (so it looked alive) while
    ser2net kept serving a stale config with every device `enable: off`, so
    every real connection was refused.

    Three independent defences, because the cause of the original death was
    never identified:

      1. The watchdog task (the one that actually works).  A SEPARATE task on
         a plain repeating schedule runs watchdog.ps1, which starts the boot
         task if no loop is running.  It uses `schtasks /Run`, which starts an
         instance regardless of what the main task believes about its state.

      2. Restart on failure.  Task Scheduler relaunches the action if the
         instance dies unexpectedly.

      3. Repeat trigger on the boot trigger.  Measured NOT to fire with a
         confirmed-dead loop within 165 s - kept because it is harmless, but
         nothing here relies on it.  (A MINUTE trigger builds the exact same
         Repetition property and works fine, which is why the watchdog is its
         own task rather than a repetition of this one.)

    Defences 2 and 3 are only safe if autostart.ps1 refuses to run a second
    copy - it takes a named mutex at startup for exactly that reason.  This
    script assumes that guard is in place; it does not check it (checking
    would mean killing the loop to see what happens, which is the thing we
    cannot do unattended).

    Idempotent: safe to re-run.  Run as Administrator (UAC prompt).
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $TaskName = 'ser2net-consolehub',
    [string] $RepeatEvery = 'PT10M',       # DMTF interval, PT10M = every 10 minutes
    [string] $FailRestartInterval = 'PT1M',
    [int]    $FailRestartCount = 999,
    [int]    $WatchdogEveryMinutes = 3,    # watchdog task: check every N minutes
    [switch] $ReportOnly
)

$ErrorActionPreference = 'Stop'

function L {
    param([string] $m, [ConsoleColor] $Color)
    if ($PSBoundParameters.ContainsKey('Color')) { Write-Host $m -ForegroundColor $Color }
    else                                          { Write-Host $m }
}

# ---------------------------------------------------------------- locate task
# "you are not allowed to see it" and "it does not exist" both come back from
# Get-ScheduledTask as an empty result, and schtasks answers BOTH with a
# localized error message - so matching on its text cannot tell them apart in
# every language.  Decide it from the elevation state instead, which is
# language-independent and actually the thing we need to know.
$task = $null
try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { }
if (-not $task) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        L "FAIL: task '$TaskName' is not visible to this unelevated shell."
        L '      (it may well exist - run this as Administrator to find out)'
        exit 1
    }
    L "FAIL: task '$TaskName' not found - run install-boot-task.ps1 first."
    exit 1
}
L "task    : $($task.TaskPath)$($task.TaskName)"
L "state   : $($task.State)"
L ('trigger : ' + (($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', '))

if ($ReportOnly) {
    L ''
    L '-- current settings (ReportOnly) --'
    L "  MultipleInstances        : $($task.Settings.MultipleInstances)"
    L "  RestartInterval          : '$($task.Settings.RestartInterval)'"
    L "  RestartCount            : $($task.Settings.RestartCount)"
    foreach ($t in $task.Triggers) {
        L "  repetition.Interval     : '$($t.Repetition.Interval)'"
        L "  repetition.Duration     : '$($t.Repetition.Duration)'"
    }
    $wd = $null
    try { $wd = Get-ScheduledTask -TaskName "$TaskName-watchdog" -ErrorAction Stop } catch { }
    L "  watchdog task           : $(if ($wd) { "$($wd.State), every $($wd.Triggers[0].Repetition.Interval)" } else { 'MISSING - no self-heal' })"
    exit 0
}

# ------------------------------------------------------------- apply settings
# Ordered most-important-first, each guarded, because a half-applied guard is
# worse than an applied one.  (The order matters for more than tidiness: the
# CIM property is MultipleInstances while the task XML calls it
# MultipleInstancesPolicy, and on a box where that name differs, the first
# property to throw used to abort the script before anything at all was set.)
function Set-Prop {
    param($Object, [string] $Name, $Value, [string] $Why)
    try {
        $Object.$Name = $Value
        L "  set $Name = $Value  ($Why)"
        return $true
    } catch {
        L "  WARN: could not set $Name - $($_.Exception.Message)"
        return $false
    }
}

# 1) Repetition on the boot trigger.  Kept, but NOT what we rely on: measured
#    to produce no new instance within 165 s after a confirmed kill.  Empty
#    Duration = "indefinitely".  The real self-heal is the watchdog task below.
if (-not $task.Triggers -or $task.Triggers.Count -eq 0) {
    L 'WARN: task has no trigger - cannot set repetition'
} else {
    foreach ($t in $task.Triggers) {
        try {
            $t.Repetition.Interval = $RepeatEvery
            $t.Repetition.Duration = ''
            if ($t.Repetition.PSObject.Properties.Name -contains 'StopAtDurationEnd') {
                $t.Repetition.StopAtDurationEnd = $false
            }
            L "  set repetition = every $RepeatEvery, indefinitely  (secondary defence)"
        } catch {
            L "WARN: $($t.CimClass.CimClassName) rejected repetition: $($_.Exception.Message)"
        }
    }
}

# 2) "If the task fails, restart every <interval>, up to <count> times."  A
#    nonzero interval is what turns the feature on.
Set-Prop $task.Settings 'RestartInterval'  $FailRestartInterval 'restart on failure' | Out-Null
Set-Prop $task.Settings 'RestartCount'     $FailRestartCount    'restart on failure' | Out-Null

# 3) Only if a launch happens while one is already running (routine once the
#    repeat timer exists), do not start a second one.  autostart's mutex would
#    catch it anyway; this just keeps Task Scheduler from even trying.
Set-Prop $task.Settings 'MultipleInstances' 'IgnoreNew' 'do not start a second loop' | Out-Null

try {
    Set-ScheduledTask -TaskName $TaskName -Trigger $task.Triggers -Settings $task.Settings | Out-Null
} catch {
    L "FAIL: Set-ScheduledTask rejected the change - $($_.Exception.Message)"
    exit 3
}

# ------------------------------------------------------- the watchdog task
# This is the defence that has to work.  It is a SEPARATE task on a MINUTE
# schedule (not a repetition of the boot trigger above, which is gated on this
# task's own state) and it relaunches with `schtasks /Run`, which starts an
# instance whatever the main task thinks.  Its own state cannot be affected by
# what happens to the loop it is watching, which is the entire point.
$WdTask = "$TaskName-watchdog"
$WdScript = Join-Path $PSScriptRoot 'watchdog.ps1'
$wdOk = $true
if (-not (Test-Path $WdScript)) {
    $wdOk = $false
    L "FAIL: $WdScript not found - no watchdog can be installed"
} else {
    $wdTr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $WdScript + '"'
    $wantInterval = "PT${WatchdogEveryMinutes}M"
    $existing = $null
    try { $existing = Get-ScheduledTask -TaskName $WdTask -ErrorAction Stop } catch { }

    # Recreate only when something is actually wrong.  /F deletes and rebuilds
    # the task, and it can refuse while an instance is running - which is the
    # normal state of this one, so an unconditional rebuild would be a coin toss
    # on every run.  Checking first also means the common case is a no-op.
    $needCreate = $true
    if ($existing) {
        $curInterval = $existing.Triggers[0].Repetition.Interval
        $curAction   = ($existing.Actions | ForEach-Object { $_.Arguments }) -join ''
        $intervalOk  = ($curInterval -eq $wantInterval)
        $actionOk    = ($curAction -match 'watchdog\.ps1')
        if ($intervalOk -and $actionOk) {
            $needCreate = $false
            L "  watchdog: already every $WatchdogEveryMinutes min with the right action - left alone"
        } else {
            L "  watchdog: fixing (interval '$curInterval' vs '$wantInterval', action ok=$actionOk)"
        }
    } else {
        L "  creating watchdog task '$WdTask' (every $WatchdogEveryMinutes min, as SYSTEM)"
    }

    if ($needCreate) {
        $wout = schtasks /Create /TN $WdTask /TR $wdTr /SC MINUTE /MO $WatchdogEveryMinutes /RU SYSTEM /RL HIGHEST /F 2>&1
        $wcode = $LASTEXITCODE
        if ($wcode -ne 0) {
            $wdOk = $false
            L "  FAIL: schtasks /Create watchdog exit=$wcode $((($wout | ForEach-Object { "$_" }) -join ' ').Trim())"
        }
    }

    # Read back: a watchdog that was silently not created is the same lie as
    # one that is not running.
    $afterWd = $null
    try { $afterWd = Get-ScheduledTask -TaskName $WdTask -ErrorAction Stop } catch { }
    if ($afterWd) {
        L "  watchdog: $($afterWd.State)  trigger=$($afterWd.Triggers[0].CimClass.CimClassName)  interval=$($afterWd.Triggers[0].Repetition.Interval)  run as $($afterWd.Principal.UserId)"
        if ($afterWd.Triggers[0].Repetition.Interval -ne $wantInterval) {
            $wdOk = $false
            L "  WARN: watchdog interval did not stick (expected $wantInterval)"
        }
        if ((($afterWd.Actions | ForEach-Object { $_.Arguments }) -join '') -notmatch 'watchdog\.ps1') {
            $wdOk = $false
            L '  WARN: watchdog action does not point at watchdog.ps1'
        }
    } else {
        $wdOk = $false
        L '  FAIL: watchdog task is not readable after creation - self-heal is NOT in place'
    }
}

# ------------------------------------------------------------------ verify back
# Reading back what was actually stored, not what we think we wrote: Task
# Scheduler silently drops settings it does not accept for a given trigger
# type, and a self-healing guard that was silently dropped is worse than none,
# because it looks like protection.
$after = Get-ScheduledTask -TaskName $TaskName
L ''
L '-- applied (read back from Task Scheduler) --'
L "  MultipleInstances        : $($after.Settings.MultipleInstances)"
L "  RestartInterval          : '$($after.Settings.RestartInterval)'"
L "  RestartCount             : $($after.Settings.RestartCount)"
foreach ($t in $after.Triggers) {
    L "  repetition.Interval      : '$($t.Repetition.Interval)'"
    L "  repetition.Duration      : '$($t.Repetition.Duration)'"
}

$ok = $true
if (-not $wdOk) { $ok = $false; L '  WARN: WATCHDOG NOT IN PLACE - the loop would not come back if it died' }
if ($after.Settings.MultipleInstances -ne 'IgnoreNew') { $ok = $false; L '  WARN: MultipleInstances did not stick (a second loop could start)' }
if ([string]::IsNullOrWhiteSpace([string] $after.Settings.RestartInterval)) { $ok = $false; L '  WARN: RestartInterval did not stick (restart-on-failure OFF)' }
if ($after.Triggers[0].Repetition.Interval -ne $RepeatEvery) {
    $ok = $false
    L "  WARN: repetition did not stick (expected $RepeatEvery) - SELF-HEAL OFF"
}
if ($ok) { L '' ; L 'self-heal settings applied.' -ForegroundColor Green }
else      { L '' ; L 'PARTIAL - see warnings above.' -ForegroundColor Yellow }

exit $(if ($ok) { 0 } else { 2 })
