<#
    deploy-on-target.ps1 - one-shot installer to run ON the TARGET machine.
    Fetched to the target via pscp, then executed through a plink SSH shell.

      1) unzip the package zip  ->  C:\ser2net
      2) verify / fix settings.json bindIp  (must match the machine's own IP)
      3) register SYSTEM boot task via install-boot-task.ps1 (auto /Run's it)
      4) firewall inbound rule 4000-4015 if any profile is enabled
      5) wait, then dump status + listeners

    Log: <USERPROFILE>\ser2net-deploy.log
#>
param(
    [string]$Zip  = "$env:USERPROFILE\ser2net-deploy.zip",
    [string]$Dest = "C:\ser2net"
)
$ErrorActionPreference = 'Continue'
$log = "$env:USERPROFILE\ser2net-deploy.log"
function Say { param($m) $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m; Add-Content -Path $log -Value $line; Write-Host $m }

Say '=== deploy-on-target start ==='
Say "zip=$Zip dest=$Dest user=$env:USERNAME"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Say "isadmin=$isAdmin"

if (-not (Test-Path $Zip)) { Say "FAIL: zip not found: $Zip"; exit 1 }
Say "powershell=$($PSVersionTable.PSVersion)"

# ---- 1. unzip into a clean target dir --------------------------------
if (Test-Path $Dest) {
    Say "removing existing $Dest"
    Remove-Item $Dest -Recurse -Force
}
try {
    Expand-Archive -Path $Zip -DestinationPath $Dest -Force
    Say "unzipped OK -> $Dest"
} catch {
    Say "FAIL unzip: $($_.Exception.Message)"
    exit 1
}

# ---- 2. settings.json - confirm bindIp --------------------------------
$set = Join-Path $Dest 'settings.json'
$txt = Get-Content -Raw -Encoding UTF8 $set
$m = [regex]::Match($txt, '"bindIp":\s*"([^"]*)"')
$ip = if ($m.Success) { $m.Groups[1].Value } else { '<none>' }
Say "settings bindIp=$ip"
if (-not $m.Success -or $ip -eq '0.0.0.0') {
    $local = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
              Select-Object -First 1).IPAddress
    if ($local) {
        Say "rewriting bindIp -> $local"
        $txt = $txt -replace '"bindIp":\s*"[^"]*"', ('"bindIp":  "' + $local + '"')
        [System.IO.File]::WriteAllText($set, $txt, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        Say 'WARN: no usable IPv4 found, leaving bindIp as-is'
    }
}

# ---- 3. USB-serial inventory (informational) ---------------------------
$ports = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '\(COM\d+\)' })
Say ("USB-serial COM ports present: " + $ports.Count)
foreach ($p in $ports) {
    $com = ($p.Name -replace '.*\(', '') -replace '\).*', ''
    Say ("  COM$com  id=" + $p.DeviceID)
}

# ---- 4. boot task (needs the elevated session) -------------------------
$boot = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'bin\install-boot-task.ps1') 2>&1
$boot | ForEach-Object { Say ("boottask: " + $_) }
Say ('boottask-launcher exit: ' + $LASTEXITCODE)

# ---- 5. firewall -------------------------------------------------------
try {
    $prof = @(Get-NetFirewallProfile -ErrorAction Stop)
    $enabled = @($prof | Where-Object { $_.Enabled }).Count
    Say ("firewall profiles enabled=" + $enabled + "/" + $prof.Count)
    if ($enabled -gt 0) {
        $r = netsh advfirewall firewall add rule name="ser2net-console 4000-4015" dir=in action=allow protocol=TCP localport=4000-4015
        $r | ForEach-Object { Say ("fwrule: " + $_) }
    } else {
        Say 'firewall all disabled - no rule needed'
    }
} catch {
    Say "firewall check failed: $($_.Exception.Message)"
}

# ---- 6. wait for the SYSTEM autostart loop, then verify ----------------
Start-Sleep -Seconds 10
$st = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'bin\serial-hub.ps1') status 2>&1
$st | ForEach-Object { Say ("status: " + $_) }
$st | Out-File (Join-Path $Dest 'logs\first-status.txt') -Encoding UTF8

$ls = @(netstat -ano | Select-String 'TCP' | Select-String 'LISTENING' | Select-String ':40[0-9][0-9]\s')
Say ('listeners on 40xx: ' + $ls.Count)
$ls | ForEach-Object { Say ("  " + $_.Line.Trim()) }
if ($ls.Count -eq 0) { Say 'listen: NONE on 40xx yet' }

Say '=== deploy-on-target done ==='
exit 0