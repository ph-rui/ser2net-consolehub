<#
    install-boot-task.ps1 v3 - register the console bridge as a BOOT task
    (LocalSystem, no login required).  Uses schtasks.exe directly so the
    registration goes straight into the Task Scheduler store.

    v3: fully path-relative ($PSScriptRoot) - runs from ANY install directory
    on ANY machine; no more hardcoded C:\Users\... paths.

    Idempotent.  Run once as Administrator (UAC prompt).
    Remove later with:   schtasks /Delete /TN ser2net-consolehub /F
#>
$ErrorActionPreference = 'Continue'
$root   = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$out  = Join-Path $logDir 'boottask-install.log'
$task = 'ser2net-consolehub'

Start-Transcript -Path $out -Force

# ---- stop orphan autostart loops already running from the old Run entry ---
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'bin\\autostart\.ps1' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "killed old autostart loop pid $($_.ProcessId)"
    }

# ---- register via schtasks.exe ---------------------------------------------
$auto = Join-Path $PSScriptRoot 'autostart.ps1'
$tr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $auto + '"'
Write-Host '== schtasks /Create =='
& schtasks /Create /TN $task /TR $tr /SC ONSTART /RU SYSTEM /RL HIGHEST /F 2>&1
Write-Host "create exit: $LASTEXITCODE"

# ---- self-healing settings (restart-on-failure + repeat trigger) ------------
# Registering the task is not enough: if the loop process dies, nothing used to
# bring it back, and the whole bridge goes silently dead (observed: a week of
# "ser2net running, every port closed").  Idempotent, and it verifies what it
# wrote - Task Scheduler silently drops settings a trigger type will not take,
# and a guard that looks applied but is not is worse than no guard.
Write-Host ''
Write-Host '== harden (self-healing settings) =='
$harden = Join-Path $PSScriptRoot 'harden-boot-task.ps1'
if (Test-Path $harden) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $harden -TaskName $task
    Write-Host "harden exit: $LASTEXITCODE"
} else {
    Write-Host 'SKIPPED: harden-boot-task.ps1 not found'
}

Write-Host ''
Write-Host '== schtasks /Query (right after create) =='
& schtasks /Query /TN $task /V /FO LIST 2>&1 | Select-String -Pattern 'TaskName|Status|Result|Run As|Logon Mode|Last Run|Next Run'
Write-Host "query exit: $LASTEXITCODE"

Write-Host ''
Write-Host '== schtasks /Run (validate now, no login needed) =='
& schtasks /Run /TN $task 2>&1
Write-Host "run exit: $LASTEXITCODE"

Write-Host ''
Write-Host 'done.'
Stop-Transcript