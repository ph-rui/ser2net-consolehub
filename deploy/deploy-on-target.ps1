<#
    deploy-on-target.ps1 - one-shot installer to run ON the TARGET machine.
    Fetched to the target via pscp, then executed through a plink SSH shell.

      1) unzip the package zip  ->  Dest (default C:\ser2net)
      2) fix settings.json bindIp AND advertiseIp for THIS machine
      3) register SYSTEM boot task via install-boot-task.ps1 (auto /Run's it)
      4) harden it via harden-boot-task.ps1 (restart-on-failure + watchdog)
      5) firewall inbound: serial ports + the query port (4099 by default)
      6) wait, then dump status + listeners and prove the query port answers

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

# ---- 2. settings.json - bindIp / advertiseIp must match THIS machine ----
# The package is built on another box and carries that box's addresses, so a
# plain unzip would leave bindIp pointing at a NIC that does not exist here
# (nothing listens) and advertiseIp telling every client to connect to the OLD
# machine (they reach the wrong boards).  Both are corrected below.
function Get-LocalIPv4 {
    $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254*' } |
               Select-Object -ExpandProperty IPAddress)
    if ($addrs.Count -eq 0) { return $null }
    try {
        $primary = (Get-NetIPConfiguration -ErrorAction Stop |
                    Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
                    Select-Object -First 1).IPv4Address.IPAddress
        if ($primary -and $addrs -contains $primary) { return $primary }
    } catch { }
    return $addrs[0]
}
function Get-SettingValue { param($Text, $Name)
    $m = [regex]::Match($Text, '"' + $Name + '":\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}
function Set-SettingValue { param($Text, $Name, $Value)
    $pattern = '"' + $Name + '":\s*"[^"]*"'
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, ('"' + $Name + '":  "' + $Value + '"'))
    }
    # key absent: insert it right after the opening brace
    return [regex]::Replace($Text, '^\{', ('{' + "`n    `"$Name`":  `"$Value`","))
}

$set = Join-Path $Dest 'settings.json'
$txt = Get-Content -Raw -Encoding UTF8 $set
$local = Get-LocalIPv4
$localAddrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty IPAddress)

$bind = Get-SettingValue $txt 'bindIp'
$adv  = Get-SettingValue $txt 'advertiseIp'
$bindOk = [bool]($bind -and $bind -ne '0.0.0.0' -and ($localAddrs -contains $bind))
$advOk  = [bool]($adv  -and $adv  -ne '0.0.0.0' -and ($localAddrs -contains $adv))
Say "settings bindIp=$bind advertiseIp=$adv  (local: $($localAddrs -join ', '))"

if (-not $local) {
    Say 'WARN: no usable IPv4 found, leaving bindIp/advertiseIp as-is'
} else {
    if (-not $bindOk) {
        Say "rewriting bindIp $bind -> $local"
        $txt = Set-SettingValue $txt 'bindIp' $local
    }
    if (-not $advOk) {
        Say "rewriting advertiseIp $adv -> $local"
        $txt = Set-SettingValue $txt 'advertiseIp' $local
    }
    if (-not $bindOk -or -not $advOk) {
        [System.IO.File]::WriteAllText($set, $txt, (New-Object System.Text.UTF8Encoding($false)))
        Say 'settings.json updated'
    } else {
        Say 'settings.json already matches this machine - left alone'
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

# ---- 4. boot task + hardening (needs the elevated session) -------------
$boot = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'bin\install-boot-task.ps1') 2>&1
$boot | ForEach-Object { Say ("boottask: " + $_) }
Say ('boottask-launcher exit: ' + $LASTEXITCODE)

# install-boot-task registers only the ONSTART task.  harden-boot-task adds the
# restart-on-failure policy and the separate watchdog task; without it a loop
# that dies stays dead until the next reboot.
$hard = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'bin\harden-boot-task.ps1') 2>&1
$hard | ForEach-Object { Say ("harden: " + $_) }
Say ('harden-launcher exit: ' + $LASTEXITCODE)

# ---- 5. firewall -------------------------------------------------------
# 4099 is the query server.  Without it ser2net's ports work while every
# Linux client still says "hub did not answer".
$queryPort = 4099
$q = [regex]::Match($txt, '"queryPort":\s*([0-9]+)')
if ($q.Success) { $queryPort = [int] $q.Groups[1].Value }
$serialPorts = '4000-4015'
$fwPorts = if ($queryPort -ge 4000 -and $queryPort -le 4015) { $serialPorts } else { "$serialPorts,$queryPort" }
try {
    $prof = @(Get-NetFirewallProfile -ErrorAction Stop)
    $enabled = @($prof | Where-Object { $_.Enabled }).Count
    Say ("firewall profiles enabled=" + $enabled + "/" + $prof.Count)
    if ($enabled -gt 0) {
        foreach ($n in @('ser2net-console', 'ser2net-console 4000-4015')) {
            $null = netsh advfirewall firewall delete rule name="$n" 2>&1
        }
        $r = netsh advfirewall firewall add rule name="ser2net-console" dir=in action=allow protocol=TCP localport=$fwPorts
        $r | ForEach-Object { Say ("fwrule: " + $_) }
        Say "firewall rule covers TCP $fwPorts"
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

# The query port is the one failure that looks like a client bug, so check it
# explicitly instead of trusting the serial listeners above.
$ql = @(netstat -ano | Select-String 'LISTENING' | Select-String (':' + $queryPort + '\s'))
if ($ql.Count -gt 0) {
    Say "query port ${queryPort}: listening"
} else {
    Say "query port ${queryPort}: NOT LISTENING - Linux clients will fail; check logs\query-server.log"
}

Say '=== deploy-on-target done ==='
exit 0