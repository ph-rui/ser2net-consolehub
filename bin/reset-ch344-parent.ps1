# reset-ch344-parent.ps1 -- ELEVATED (UAC): full driver reload of CH344 adapter #1
# (composite USB\VID_1A86&PID_55D5\0123456789) to clear the zombie IRP wedging
# COM99.  Then drops a restart marker so the SYSTEM autostart loop re-starts
# ser2net (keeps SYSTEM ownership, no manual step).
$ErrorActionPreference = 'Continue'
$Root    = Split-Path -Parent $PSScriptRoot
$log     = Join-Path $Root 'logs\ch344-parent-reset.log'
$Request  = Join-Path $Root 'restart.request'
$Hub     = Join-Path $PSScriptRoot 'serial-hub.ps1'
function L([string] $m) {
    ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) |
        Out-File -FilePath $log -Append -Encoding utf8
}

# 1) stop ser2net (elevated can kill the SYSTEM-owned process)
L 'stopping ser2net ...'
Get-CimInstance Win32_Process -Filter "Name='ser2net.exe'" |
    ForEach-Object { L "  killing pid $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Seconds 2

# 2) reload the composite device (all four MI interfaces)
$parent = 'USB\VID_1A86&PID_55D5\0123456789'
$dev = Get-PnpDevice -InstanceId $parent -ErrorAction SilentlyContinue
if (-not $dev) {
    L "parent not found: $parent - nothing to reload"
} else {
    L "parent found: status=$($dev.Status) name=$($dev.FriendlyName)"
    try {
        L '  disabling parent ...'
        Disable-PnpDevice -InstanceId $parent -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3
        L "  after disable: $((Get-PnpDevice -InstanceId $parent -ErrorAction SilentlyContinue).Status)"
    } catch { L "  DISABLE ERROR: $($_.Exception.Message)" }
    try {
        L '  enabling parent ...'
        Enable-PnpDevice -InstanceId $parent -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 6
        L "  after enable: $((Get-PnpDevice -InstanceId $parent -ErrorAction SilentlyContinue).Status)"
    } catch { L "  ENABLE ERROR: $($_.Exception.Message)" }
}

# 3) report the four interfaces + their COM numbers now
Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '\(COM\d+\)' -and $_.DeviceID -like 'USB\VID_1A86&PID_55D5&MI_*\6&2FD485C6*' } |
    ForEach-Object { L ("  interface: {0}" -f $_.Name) }

# 4) let the SYSTEM loop bring ser2net back (SYSTEM ownership kept)
Set-Content -Path $Request -Value 'restart' -Encoding ASCII
L 'restart.request dropped - autostart will start ser2net shortly'
L '=== parent reset done ==='