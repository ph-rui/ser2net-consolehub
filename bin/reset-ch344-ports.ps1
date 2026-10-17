# reset-ch344-ports.ps1 -- ELEVATED (UAC): disable/enable the two CH344 "A"
# (MI_00) serial ports to clear stale driver open-state.  Hardened: kills any
# older stuck copy of itself, every step logged, never silently hangs.
$ErrorActionPreference = 'Continue'
$root   = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir 'ch344-reset.log'
function L([string] $m) {
    ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) |
        Out-File -FilePath $log -Append -Encoding utf8
}

# 1) kill stale copies of this script
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'reset-ch344-ports\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object {
        L "killing stale reset process $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force
    }

$targets = @(
    [pscustomobject]@{ Com = 99;  Id = 'USB\VID_1A86&PID_55D5&MI_00\6&2FD485C6&0&0000' },
    [pscustomobject]@{ Com = 148; Id = 'USB\VID_1A86&PID_55D5&MI_00\6&12741DE1&0&0000' }
)

foreach ($t in $targets) {
    $dev = $null
    try { $dev = Get-PnpDevice -InstanceId $t.Id -ErrorAction Stop 2>$null } catch { }
    if (-not $dev) {
        L "COM$($t.Com): device $($t.Id) not found - skipped"
        continue
    }
    L "COM$($t.Com): found device status=$($dev.Status) class=$($dev.Class)"
    try {
        L "  disabling ..."
        Disable-PnpDevice -InstanceId $t.Id -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 4
        $s1 = (Get-PnpDevice -InstanceId $t.Id -ErrorAction SilentlyContinue).Status
        L "  after disable: $s1"
    } catch { L "  DISABLE ERROR: $($_.Exception.Message)" }
    try {
        L "  enabling ..."
        Enable-PnpDevice -InstanceId $t.Id -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 4
        $s2 = (Get-PnpDevice -InstanceId $t.Id -ErrorAction SilentlyContinue).Status
        L "  after enable: $s2"
    } catch { L "  ENABLE ERROR: $($_.Exception.Message)" }
}
L '=== reset done ==='