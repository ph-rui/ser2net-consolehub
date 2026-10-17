<#
.SYNOPSIS
    USB-serial console hub for Windows: discovers every USB-serial device
    (CH344 quad + standalone adapters), keeps a stable device registry, and
    renders/supervises ser2net.

.DESCRIPTION
    Windows reassigns COM numbers on almost every replug (the same adapter
    can be COM15 today, COM42 tomorrow), so COM can never be hard-coded.

    This script keeps a device registry in devices.json:
        fingerprint (PnP DeviceID, stable across replugs)
            -> alias + label (what YOU refer to)
            -> fixed TCP port
    Every render/reconcile re-scans the USB hardware and substitutes the
    CURRENT COM number into the ser2net config.  Reconcile (called on a
    timer by autostart.ps1) restarts ser2net only when the mapping really
    changed, so a live console session is never interrupted needlessly.

    Linux side never sees a COM number: it uses the alias / label from the
    LIVE table that query-server.ps1 answers with, on every client run.

.PARAMETER Command
    discover  Scan USB, update the registry, show alias -> COM -> port.
    render    Regenerate etc\ser2net\ser2net.yaml.
    start     render, then launch ser2net in the background.
    stop      Terminate a running ser2net.
    restart   stop + start.
    status    Show process state, registry, and listeners.
    probe     Connect to each device TCP port locally and read the banner.
    logs      Tail a device trace. Use -Port 4000.
    prune     Delete trace files older than settings.traceKeepDays.
    doctor    Full self-check: paths, registry, config, ports, reachability.
    reconcile Auto alias/COM remap; restart ser2net only on changes.

.EXAMPLE
    .\serial-hub.ps1 discover
    .\serial-hub.ps1 start
    .\serial-hub.ps1 logs -Port 4000 -Tail
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('discover', 'render', 'start', 'stop', 'restart', 'status',
                 'probe', 'logs', 'prune', 'doctor', 'reconcile', 'push')]
    # 'push' is still accepted only so it fails with an explanation instead of
    # "not a valid value" - the snapshot it pushed is gone.
    [string] $Command = 'status',

    [int] $Port = 0,
    [switch] $Tail
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths
$Root       = Split-Path -Parent $PSScriptRoot
$BinDir     = Join-Path $Root 'bin'
$EtcDir     = Join-Path $Root 'etc\ser2net'
$LogDir     = Join-Path $Root 'logs'
$TplPath    = Join-Path $EtcDir 'ser2net.template.yaml'
$YamlPath   = Join-Path $EtcDir 'ser2net.yaml'
$SettingsPath = Join-Path $Root 'settings.json'
$DevicesPath  = Join-Path $Root 'devices.json'
$DevConfPath  = Join-Path $Root 'linux\devices.conf'
$StatePath  = Join-Path $Root 'ports.json'
$PidPath    = Join-Path $Root 'ser2net.pid'
$RequestPath = Join-Path $Root 'restart.request'   # user->SYSTEM autostart restart marker
$StdOut     = Join-Path $LogDir 'ser2net-stdout.log'
$StdErr     = Join-Path $LogDir 'ser2net-stderr.log'

$CH344_VIDPID = 'VID_1A86&PID_55D5'   # WCH CH344 quad USB-serial
$REG_PORT_BASE = 4000                  # first auto-assigned TCP port

# ---------------------------------------------------------------- helpers
function Write-Head { param($t) Write-Host ''; Write-Host "== $t " -NoNewline; Write-Host ('=' * [Math]::Max(0, 60 - $t.Length)) }

function Fail { param($m) Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Get-Settings {
    if (-not (Test-Path $SettingsPath)) { Fail "missing $SettingsPath" }
    # -Encoding UTF8: PS 5.1's default (ANSI) read mangles a UTF-8 file with
    # Chinese comments when it has no BOM, which breaks ConvertFrom-Json.
    Get-Content -Raw -Encoding UTF8 $SettingsPath | ConvertFrom-Json
}

function Get-ProbeIp {
    # Address to self-probe / advertise to clients.  With a wildcard bindIp
    # (0.0.0.0) probing the bind address is meaningless (Windows maps a connect
    # to 0.0.0.0 onto loopback), so prefer advertiseIp when configured.
    param($Settings)
    if ($Settings.PSObject.Properties.Name -contains 'advertiseIp' -and $Settings.advertiseIp) {
        return [string] $Settings.advertiseIp
    }
    return [string] $Settings.bindIp
}

function Find-Ser2netExe {
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $c = @(
        (Join-Path $BinDir 'ser2net.exe')
    )
    foreach ($base in @($env:ProgramFiles, $pf86)) {
        if ($base) { $c += (Join-Path $base 'Ser2Net\bin\ser2net.exe') }
    }
    foreach ($base in @($env:LOCALAPPDATA)) {
        if ($base) {
            $c += (Join-Path $base 'Ser2Net\bin\ser2net.exe')
            $c += (Join-Path $base 'Programs\Ser2Net\bin\ser2net.exe')
        }
    }

    foreach ($p in $c) { if ($p -and (Test-Path $p)) { return $p } }

    $cmd = Get-Command 'ser2net.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-ProcStart {
    # .StartTime is blank (not thrown) for SYSTEM-owned processes when the
    # caller is a non-elevated user (ser2net runs under the SYSTEM boot task),
    # so when blank fall back to Win32_Process.CreationDate, else a sentinel.
    param($p)
    $s = $null
    try { $s = $p.StartTime } catch {}
    if ($s) { return $s }
    try {
        $c = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction Stop
        if ($c -and $c.CreationDate) { return [datetime]$c.CreationDate }
    } catch {}
    return [datetime]::MinValue
}

function Get-Ser2netProc {
    $procs = @(Get-Process -Name 'ser2net' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $null }
    if ($procs.Count -gt 1) {
        Write-Host "WARNING: $($procs.Count) ser2net processes running (PIDs: $($procs.Id -join ', ')). Using the oldest." -ForegroundColor Yellow
    }
    foreach ($p in $procs) {
        $p | Add-Member -NotePropertyName _startKey -NotePropertyValue (Get-ProcStart $p) -Force
    }
    return ($procs | Sort-Object _startKey | Select-Object -First 1)
}

function Get-ListeningPort {
    # netstat-based: Get-NetTCPConnection HANGS in hidden-window child
    # PowerShell sessions on this machine (observed during bring-up), so we
    # deliberately use netstat instead.
    param([int] $PortNumber)
    $found = @()
    $lines = & netstat -ano 2>$null
    $re = '^\s*TCP\s+(\[[0-9a-f:]+\]|[0-9.]+):' + $PortNumber +
          '\s+(\[[0-9a-f:]+\]|[0-9.]+):(\d+)\s+(\S+)\s+(\d+)\s*$'
    foreach ($ln in $lines) {
        if ($ln -match $re) {
            $found += [pscustomobject]@{
                LocalAddress  = $Matches[1]
                LocalPort     = [int] $PortNumber
                RemotePort    = [int] $Matches[3]
                State         = $Matches[4]
                OwningProcess = [int] $Matches[5]
            }
        }
    }
    return ,$found
}

# ---------------------------------------------------------------- discovery
<#
    Enumerate EVERY USB serial port (CH344 quad + any standalone adapter).
    The PnP DeviceID is the stable fingerprint: it stays the same for a given
    physical device across replugs even when the COM number changes.
#>
function Get-UsbSerialDevices {
    $ents = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\(COM(\d+)\)\s*$' -and $_.DeviceID -like 'USB\*' } |
        Sort-Object Name

    $devs = @()
    foreach ($e in $ents) {
        $null = $e.Name -match '\(COM(\d+)\)\s*$'
        $devs += [pscustomobject]@{
            Fingerprint = $e.DeviceID
            Com         = [int] $Matches[1]
            Name        = ($e.Name -replace '\(COM\d+\)\s*$', '').Trim()
        }
    }
    return ,$devs
}

# ------------------------------------------------------- device registry
function Get-DevicesRegistry {
    if (-not (Test-Path $DevicesPath)) { return ,@() }
    try {
        $r = Get-Content -Raw -Encoding UTF8 $DevicesPath | ConvertFrom-Json
        $devs = @($r.devices) | Where-Object { $null -ne $_ }
        return ,$devs
    } catch { return ,@() }
}

function Save-DevicesRegistry {
    param($Devices)
    [pscustomobject]@{
        generated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        devices   = @($Devices)
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $DevicesPath -Encoding UTF8
}

function Get-NextAlias {
    param($Existing)
    for ($i = 0; $i -lt 26; $i++) {
        $a = [char](97 + $i)
        if ($a -notin $Existing) { return [string] $a }
    }
    $n = 1
    while ("$n" -in $Existing) { $n++ }
    return "$n"
}

function Get-NextPort {
    param($Used)
    $p = $REG_PORT_BASE
    while ($p -in $Used) { $p++ }
    return $p
}

<#
    Fold the live devices into the registry.  New fingerprints automatically
    get the next free alias (a,b,c...z, then 1,2,3...) and the next free port
    starting at 4000.  CH344 interfaces keep their historical letters/ports
    (a..d -> settings.json ports) so nothing that already works breaks.
    Returns @{ Devices = <merged array>; Changed = <bool> }.
#>
function Merge-LiveDevices {
    param($Live, $Registry)

    $reg       = @($Registry | Where-Object { $null -ne $_ })
    $usedAlias = @($reg | ForEach-Object { $_.alias })
    $usedPort  = @($reg | ForEach-Object { [int] $_.port })
    $changed   = $false

    # Seed mapping for the CH344 quad from settings.json historical ports.
    $settings = Get-Settings
    $chSeed   = @{}
    if ($settings.ports) {
        if ($settings.ports.a) { $chSeed['a'] = [int] $settings.ports.a }
        if ($settings.ports.b) { $chSeed['b'] = [int] $settings.ports.b }
        if ($settings.ports.c) { $chSeed['c'] = [int] $settings.ports.c }
        if ($settings.ports.d) { $chSeed['d'] = [int] $settings.ports.d }
    }

    foreach ($d in $Live) {
        if ($reg | Where-Object { $_.fingerprint -eq $d.Fingerprint }) { continue }

        $alias = $null
        $port  = $null
        if ($d.Fingerprint -like "*$CH344_VIDPID*") {
            $idx = -1
            if ($d.Fingerprint -match '&MI_([0-9A-Fa-f]{2})') {
                $idx = [Convert]::ToInt32($Matches[1], 16) / 2
            }
            if ($idx -ge 0 -and $idx -le 3) {
                # Historical letter (a..d) only when it is NOT already claimed by a
                # DIFFERENT physical device.  A second identical CH344 quad (same
                # VID/PID + MI index, different USB parent) must not steal the
                # letters/ports of the first one -- it falls through to the next
                # free alias/port instead (g/h/../1/2... and 4004+).
                $letter = ([char](97 + $idx)).ToString()
                $alreadyTaken = $reg | Where-Object { $_.alias -eq $letter } | Select-Object -First 1
                if (-not $alreadyTaken) {
                    $alias = $letter
                    if ($chSeed.ContainsKey($letter)) { $port = $chSeed[$letter] }
                }
            }
        }
        if (-not $alias) { $alias = Get-NextAlias -Existing $usedAlias }
        if (-not $port)  { $port  = Get-NextPort -Used $usedPort }

        $reg += [pscustomobject]@{
            fingerprint = $d.Fingerprint
            alias       = $alias
            label       = $d.Name
            port        = $port
            baud        = 0
        }
        $usedAlias += $alias
        $usedPort  += [int] $port
        Write-Host ("  new device:  {0}  ->  alias={1} label={2} port={3}" -f
                    $d.Com, $alias, $(if ($d.Name) { $d.Name } else { '(unnamed)' }), $port) -ForegroundColor Yellow
        $changed = $true
    }

    return @{ Devices = $reg; Changed = $changed }
}

# ------------------------------------------------------- status probe
<#
    Probe one COM port to see whether ser2net (or someone else) can claim it.
    Returns @{ Com; Device; Status; Usable; Error }.
#>
function Test-DevicePort {
    param([int] $Com, [int] $Baud, [int] $DataBits, [string] $Parity, [int] $StopBits,
          $Ser2netRunning, $PriorDev)

    # If ser2net already holds the port (it legitimately does), reuse the
    # known-good device string instead of probing.
    if ($Ser2netRunning -and $PriorDev -and $PriorDev.Usable -eq $true -and $PriorDev.Com -eq $Com) {
        return [pscustomobject]@{
            Com = $Com; Device = $PriorDev.Device; Status = 'in-use-by-ser2net'
            Usable = $true; Error = ''
        }
    }

    $device = "COM$Com"; $status = 'unknown'; $err = ''
    try {
        $sp = New-Object System.IO.Ports.SerialPort $device, $Baud, $Parity, $DataBits, $StopBits
        $sp.DtrEnable = $false; $sp.RtsEnable = $false
        $sp.ReadTimeout = 250;  $sp.WriteTimeout = 250
        $sp.Open(); $sp.Close(); $sp.Dispose()
        $status = 'ok'
    } catch {
        $err = $_.Exception.Message
        $status = 'busy-or-unavailable'
    }
    return [pscustomobject]@{
        Com = $Com; Device = $device; Status = $status
        Usable = [bool]($status -eq 'ok'); Error = $err
    }
}

<#
    Merge registry + live hardware + open-probe into the display rows.
#>
function Resolve-Devices {
    param($Live, $Registry, $Settings)

    $proc  = Get-Ser2netProc
    $prior = $null
    if (Test-Path $StatePath) {
        try { $prior = Get-Content -Raw -Encoding UTF8 $StatePath | ConvertFrom-Json } catch { $prior = $null }
    }

    $rows = @()
    foreach ($d in $Registry) {
        $lv = $Live | Where-Object { $null -ne $_ -and $_.Fingerprint -eq $d.fingerprint } | Select-Object -First 1
        $present = $null -ne $lv
        $probe = $null
        if ($present) {
            $p = $null
            if ($prior -and $prior.PSObject.Properties.Name -contains 'devices') {
                $p = $prior.devices | Where-Object { $_.Fingerprint -eq $d.fingerprint } | Select-Object -First 1
            }
            $probe = Test-DevicePort -Com $lv.Com -Baud $Settings.baud -DataBits $Settings.dataBits `
                                     -Parity $Settings.parity -StopBits $Settings.stopBits `
                                     -Ser2netRunning ($null -ne $proc) -PriorDev $p
        }
        $rows += [pscustomobject]@{
            Alias       = $d.alias
            Label       = $d.label
            Fingerprint = $d.fingerprint
            Port        = [int] $d.port
            Com         = if ($present) { $lv.Com } else { $null }
            Present     = $present
            Usable      = if ($present -and $probe) { $probe.Usable } else { $false }
            Status      = if (-not $present) { 'absent' } elseif ($probe) { $probe.Status } else { 'unknown' }
            Device      = if ($probe) { $probe.Device } else { '' }
            Error       = if ($probe -and $probe.Error) { $probe.Error } else { '' }
        }
    }
    return $rows
}

function Format-DevTable {
    param($Rows)
    $out = foreach ($r in $Rows) {
        $lb = $r.Label
        if ($lb.Length -gt 26) { $lb = $lb.Substring(0, 26) }
        [pscustomobject]@{
            Alias = $r.Alias
            Label = $lb
            COM   = if ($null -ne $r.Com) { $r.Com } else { '-' }
            TCP   = $r.Port
            Use   = if ($r.Usable) { 'yes' } else { 'NO' }
            St    = $r.Status
        }
    }
    $out | Format-Table -AutoSize
}

# ------------------------------------------------------- render
function Get-CurrentMapping {
    param($Registry, $Live)
    $tuples = foreach ($d in $Registry) {
        $lv = $Live | Where-Object { $null -ne $_ -and $_.Fingerprint -eq $d.fingerprint } | Select-Object -First 1
        $present = $null -ne $lv
        "{0}:{1}:{2}:{3}" -f $d.alias, $d.port, $(if ($present) { "COM$($lv.Com)" } else { '-' }),
                           $(if ($present) { 'up' } else { 'down' })
    }
    return (($tuples | Sort-Object) -join '|')
}

function Invoke-Render {
    param($Settings, $Registry, $Live)

    if (-not (Test-Path $TplPath)) { Fail "missing template $TplPath" }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    if (-not (Test-Path (Split-Path $DevConfPath))) { New-Item -ItemType Directory -Force -Path (Split-Path $DevConfPath) | Out-Null }
    # (the linux\ dir itself is still needed for ptybridge.py, which ships to the
    #  Linux side by hand - just no longer for a generated devices.conf)

    # bindIp is the ser2net listen address; it may be a wildcard (0.0.0.0).
    # That is NOT a usable address for a client, so anything we ADVERTISE
    # (the console banner, and the address query-server reports to clients)
    # uses advertiseIp, falling back to bindIp for single-NIC legacy configs.
    $advIp = $Settings.bindIp
    if ($Settings.PSObject.Properties.Name -contains 'advertiseIp' -and $Settings.advertiseIp) {
        $advIp = [string] $Settings.advertiseIp
    }

    $lines   = @()
    $summary = @()
    $state   = @()
    # No devices.conf is generated any more.  The Linux side asks this host's
    # query-server for the live table on every run, so a rendered snapshot had
    # no consumers and could only go stale.

    $seenAlias = @{}
    foreach ($d in $Registry) {
        if ($seenAlias.ContainsKey([string] $d.alias)) {
            # registry hygiene guard: duplicate alias would generate a broken
            # yaml (duplicate dev-<alias> key).  Merge-LiveDevices no longer
            # creates these, but a hand-edited devices.json can.
            Write-Warning ("render: duplicate alias '{0}' (fingerprint {1}) skipped - fix devices.json" -f $d.alias, $d.fingerprint)
            continue
        }
        $seenAlias[[string] $d.alias] = $true
        $lv = $Live | Where-Object { $null -ne $_ -and $_.Fingerprint -eq $d.fingerprint } | Select-Object -First 1
        $present = $null -ne $lv
        $thisBaud = if ([int] $d.baud -gt 0) { [int] $d.baud } else { [int] $Settings.baud }
        $speed = "$thisBaud$($Settings.parity)$($Settings.dataBits)$($Settings.stopBits)"

        $device = if ($present) { "COM$($lv.Com)" } else { 'COM0' }        # COM0: placeholder, never opened (enable: off)
        $name   = if ($d.label) { $d.label } else { $d.alias }

        $cn = "dev-$($d.alias)"
        $lines += "  ${cn}:"
        $lines += "    accepter: tcp,$($Settings.bindIp),$($d.port)"
        $lines += '    # timeout 0 == never idle-disconnect. A logged-in console can sit idle for hours.'
        $lines += '    # A stuck peer is still detected when data is pending (remote stops accepting).'
        $lines += "    timeout: 0"
        $lines += "    enable: $(if ($present) { 'on' } else { 'off' })"
        $lines += '    # hangup-when-done=false keeps DTR/RTS high across disconnects: closing a console'
        $lines += '    # session cannot reset the board.'
        $lines += "    connector: serialdev,$device,$speed,hangup-when-done=false"
        # maxConnections: settings.json global default (1 == kick old user);
        # devices.json per-device "maxConnections" overrides it. >1 lets several
        # readers attach to the same port (ser2net broadcasts port RX to every
        # connection); kickolduser only applies to the 1-connection mode.
        $mc = 1
        if ($d.PSObject.Properties.Name -contains 'maxConnections' -and $null -ne $d.maxConnections) {
            $mc = [int] $d.maxConnections
        } elseif ($Settings.PSObject.Properties.Name -contains 'maxConnections' -and $null -ne $Settings.maxConnections) {
            $mc = [int] $Settings.maxConnections
        }
        if ($mc -lt 1) { $mc = 1 }
        $kick = if ($mc -eq 1) { 'true' } else { 'false' }
        $lines += "    options:"
        $lines += '      banner: "{0} {1} {2} -> {3}:{4}\r\n"' -f $name, $device, $speed, $advIp, $d.port
        $lines += "      kickolduser: $kick"
        $lines += "      max-connections: $mc"
        $lines += '      trace-both: "{0}/dev-{1}.log"' -f $LogDir.Replace('\', '/'), $d.alias
        $lines += ''

        $summary += "$($d.alias)=$device"
        $state += [pscustomobject]@{
            Alias       = $d.alias
            Label       = $d.label
            Fingerprint = $d.fingerprint
            Com         = if ($present) { $lv.Com } else { $null }
            Present     = $present
            Device      = $device
            Usable      = $present
        }
    }

    $vars = @{
        BIND_IP      = $Settings.bindIp
        HOSTNAME     = $env:COMPUTERNAME
        GENERATED_AT = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        CONNECTIONS  = ($lines -join "`n")
        SLOT_SUMMARY = ($summary -join '  ')
    }

    $text = [System.IO.File]::ReadAllText($TplPath)
    foreach ($k in $vars.Keys) { $text = $text.Replace('{{' + $k + '}}', [string] $vars[$k]) }

    $left = [regex]::Matches($text, '\{\{[A-Za-z0-9_]+\}\}')
    if ($left.Count -gt 0) {
        $names = ($left | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', '
        Fail "unresolved placeholder(s) in template: $names"
    }

    [System.IO.File]::WriteAllText($YamlPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    # If a devices.conf from the old snapshot era is still lying around, take it
    # with us: leaving it invites somebody to trust a stale device table.
    if (Test-Path $DevConfPath) {
        Remove-Item $DevConfPath -Force
        Write-Host "removed stale $DevConfPath (snapshot model is gone)" -ForegroundColor DarkGray
    }

    [pscustomobject]@{
        GeneratedAt = $vars['GENERATED_AT']
        BindIp      = $Settings.bindIp
        Yaml        = $YamlPath
        Mapping     = Get-CurrentMapping -Registry $Registry -Live $Live
        Devices     = $state
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8

    Write-Host "wrote $YamlPath" -ForegroundColor Green
    return $state
}

# ---------------------------------------------------------------- lifecycle
function Start-Ser2net {
    param($Settings)

    $exe = Find-Ser2netExe
    if (-not $exe) {
        Fail "ser2net.exe not found. Install it, or drop the exe into $BinDir. See README.md."
    }
    Write-Host "exe    : $exe"
    Write-Host "config : $YamlPath"
    Write-Host ''

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

    $serArgs = ('-n -d -c "{0}" -C "{1}"' -f $YamlPath, $EtcDir)

    # ---- 1) validate the config: run a foreground copy for 2.5 s. ----------
    # Config passes the check if the process is still alive after the window.
    # (ser2net opens the COM ports lazily on connect, so the probe does not
    # bind them and cannot disturb MobaXterm or a board console.)
    $vpsi = New-Object System.Diagnostics.ProcessStartInfo
    $vpsi.FileName = $exe
    $vpsi.Arguments = $serArgs
    $vpsi.UseShellExecute = $false
    $vpsi.CreateNoWindow = $true
    $vpsi.RedirectStandardOutput = $true
    $vpsi.RedirectStandardError = $true
    $vp = [System.Diagnostics.Process]::Start($vpsi)
    $exited = $vp.WaitForExit(2500)
    if ($exited) {
        $vp.WaitForExit()
        $msg = ($vp.StandardError.ReadToEnd() + $vp.StandardOutput.ReadToEnd()).Trim()
        Write-Host 'ser2net config check FAILED (process exited immediately).' -ForegroundColor Red
        if ($msg) { $msg -split "`n" | ForEach-Object { Write-Host $_ -ForegroundColor Red } }
        Fail 'start failed: bad config or missing device'
    }
    if (-not $vp.HasExited) { $vp.Kill() }
    $vp.WaitForExit()
    Write-Host 'config check passed (2.5 s probe run, killed).' -ForegroundColor DarkGray

    # ---- 2) launch detached. -----------------------------------------------
    # ShellExecute launch with NO -Redirect*: PS 5.1's Start-Process
    # -Redirect* keeps a background drain job alive until the child exits,
    # which would make every `start` call hang until ser2net dies.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $serArgs
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $null = [System.Diagnostics.Process]::Start($psi)

    # ---- 3) confirm it came up. ---------------------------------------------
    Start-Sleep -Milliseconds 1500
    $alive = Get-Ser2netProc
    if (-not $alive) {
        Write-Host 'ser2net exited right after launch.' -ForegroundColor Red
        if (Test-Path $StdErr) { Get-Content $StdErr -Tail 30 | ForEach-Object { Write-Host $_ -ForegroundColor Red } }
        if (Test-Path $StdOut) { Get-Content $StdOut -Tail 30 | ForEach-Object { Write-Host $_ -ForegroundColor Red } }
        Fail 'start failed'
    }

    $alive.Id | Set-Content -Path $PidPath -Encoding ASCII
    Write-Host "started, pid $($alive.Id)" -ForegroundColor Green
}

function Stop-Ser2net {
    # Returns $true if ser2net is stopped (or wasn't running), $false if it is
    # still alive (e.g. it is owned by the SYSTEM boot task and this is a
    # non-elevated user shell - see the 'restart'/'stop' fallback via the
    # restart.request marker).
    $p = Get-Ser2netProc
    if (-not $p) { Write-Host 'ser2net is not running.'; if (Test-Path $PidPath) { Remove-Item $PidPath -Force }; return $true }
    Write-Host "stopping pid $($p.Id) ..."
    try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
        Write-Host "stop failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    Start-Sleep -Milliseconds 400
    if (Test-Path $PidPath) { Remove-Item $PidPath -Force }
    Write-Host 'stopped.' -ForegroundColor Green
    return $true
}

function Request-SystemRestart {
    # ser2net is owned by the SYSTEM boot task loop, so a non-elevated user
    # shell cannot stop/restart it.  Drop a marker file; the autostart loop
    # (running as SYSTEM, every 15 s) consumes it and does stop+start itself.
    param([int] $OldPid = 0)
    Set-Content -Path $RequestPath -Value 'restart' -Encoding ASCII
    Write-Host 'ser2net is owned by the SYSTEM boot task - restart.request dropped, waiting for autostart (≤ ~90 s)...' -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds(90)
    $new = $null
    while ((Get-Date) -lt $deadline) {
        $new = Get-Ser2netProc
        if ($new -and $new.Id -ne $OldPid) { break }
        Start-Sleep -Milliseconds 1500
    }
    if ($new -and $new.Id -ne $OldPid) {
        Write-Host "restarted (pid $($new.Id))." -ForegroundColor Green
        return $true
    }
    if (-not (Get-Ser2netProc)) {
        Write-Host 'ser2net not running (stop applied, no new start observed) - check logs\autostart.log' -ForegroundColor Yellow
        return $true
    }
    Write-Host 'no restart observed yet - check logs\autostart.log (is the boot task loop running?)' -ForegroundColor Yellow
    return $false
}

# ---------------------------------------------------------------- probe
function Test-PortBanner {
    param([string] $BindIp, [int] $PortNumber, [int] $TimeoutMs = 2500)

    $l = Get-ListeningPort -PortNumber $PortNumber
    if (-not $l) {
        [pscustomobject]@{ Port = $PortNumber; Listening = $false; Banner = '<not listening>'; Ok = $false }
        return
    }
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($BindIp, $PortNumber, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw 'connect timeout' }
        $c.EndConnect($iar)
        $ns = $c.GetStream()
        $ns.ReadTimeout = $TimeoutMs
        $buf = New-Object byte[] 512
        $n = $ns.Read($buf, 0, 512)
        [pscustomobject]@{
            Port = $PortNumber; Listening = $true
            Banner = [System.Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Max(0, $n))
            Ok = ($n -gt 0)
        }
    } catch {
        [pscustomobject]@{ Port = $PortNumber; Listening = $true; Banner = "<error: $($_.Exception.Message)>"; Ok = $false }
    } finally {
        $c.Close()
    }
}

# ---------------------------------------------------------------- dispatcher
$settings = Get-Settings

switch ($Command) {

    'discover' {
        Write-Head 'usb serial scan'
        $live = Get-UsbSerialDevices
        $reg  = Get-DevicesRegistry
        $merge = Merge-LiveDevices -Live $live -Registry $reg
        if ($merge.Changed) { Save-DevicesRegistry -Devices $merge.Devices; $reg = $merge.Devices }

        Write-Head 'device registry'
        if ($reg.Count -eq 0) { Write-Host 'registry empty - nothing ever seen yet.' -ForegroundColor Yellow }
        $rows = Resolve-Devices -Live $live -Registry $reg -Settings $settings
        Format-DevTable -Rows $rows

        Write-Host ''
        Write-Host ('registry       : {0}' -f $DevicesPath)
        Write-Host 'edit devices.json to rename labels or fix TCP ports.'
        Write-Host 'the Linux side reads the live table from this host; nothing to copy.' -ForegroundColor DarkGray
    }

    'render' {
        Write-Head 'discover'
        $live = Get-UsbSerialDevices
        $reg  = Get-DevicesRegistry
        $merge = Merge-LiveDevices -Live $live -Registry $reg
        if ($merge.Changed) { Save-DevicesRegistry -Devices $merge.Devices; $reg = $merge.Devices }
        $rows = Resolve-Devices -Live $live -Registry $reg -Settings $settings
        Format-DevTable -Rows $rows

        Write-Head 'render'
        $null = Invoke-Render -Settings $settings -Registry $reg -Live $live
    }

    'start' {
        $running = Get-Ser2netProc
        if ($running) {
            Write-Host "ser2net already running (pid $($running.Id)). Use 'restart' to force a restart." -ForegroundColor Yellow
            break
        }
        Write-Head 'discover'
        $live = Get-UsbSerialDevices
        $reg  = Get-DevicesRegistry
        $merge = Merge-LiveDevices -Live $live -Registry $reg
        if ($merge.Changed) { Save-DevicesRegistry -Devices $merge.Devices; $reg = $merge.Devices }
        $rows = Resolve-Devices -Live $live -Registry $reg -Settings $settings
        Format-DevTable -Rows $rows

        Write-Head 'render'
        $null = Invoke-Render -Settings $settings -Registry $reg -Live $live

        Write-Head 'start'
        Start-Ser2net -Settings $settings
    }

    'stop'   {
        Write-Head 'stop'
        if (Stop-Ser2net) { return }
        # ser2net is SYSTEM-owned: ask the autostart loop to stop it.
        Set-Content -Path $RequestPath -Value 'stop' -Encoding ASCII
        Write-Host 'ser2net is owned by the SYSTEM boot task - requesting stop via autostart...' -ForegroundColor Yellow
        $deadline = (Get-Date).AddSeconds(45)
        $gone = $false
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Ser2netProc)) { $gone = $true; break }
            Start-Sleep -Milliseconds 1500
        }
        if ($gone) { Write-Host 'stopped (via autostart).' -ForegroundColor Green }
        else       { Write-Host 'still running - check logs\autostart.log (is the boot task loop up?)' -ForegroundColor Yellow }
    }

    'restart' {
        Write-Head 'stop'
        $old = Get-Ser2netProc
        if ($old -and -not (Stop-Ser2net)) {
            # SYSTEM-owned: full restart delegated to the autostart loop.
            $null = Request-SystemRestart -OldPid $old.Id
            return
        }
        Write-Head 'start'
        & $PSCommandPath start
    }

    'push' {
        # Removed: there is nothing left to push.  `push` used to copy
        # linux\devices.conf to the Linux box.  That file was a snapshot, and the
        # Linux side now asks the hub's query-server for the live table on every
        # run, so the snapshot had no consumers - it could only go stale.
        # A client that cannot reach the hub now fails loudly instead of quietly
        # using an old list, which is the behaviour you want.
        Fail ("'push' no longer exists - the pull model replaced it. The Linux side asks this " +
              "host's query-server (port $($Settings.queryPort)) for the device table on every " +
              "run, so there is no snapshot to distribute. Nothing to do.")
    }

    'reconcile' {
        # Idempotent "make reality match the config". Safe to call on a timer:
        # it restarts ser2net ONLY when the device/COM mapping really changed,
        # so a running console session is left alone otherwise.
        $proc = Get-Ser2netProc

        if (-not $proc) {
            Write-Host 'ser2net is not running - starting it.' -ForegroundColor Yellow
            & $PSCommandPath start
            return
        }

        # A re-render that nobody restarted after (a hand-run `render`, a
        # half-finished repair) leaves ser2net serving the OLD config while
        # ports.json already records the new mapping - and then the mapping
        # check below compares EQUAL, so the discrepancy stays invisible
        # forever.  That is how a bridge can look completely healthy (query
        # server answers --list, ser2net is running) while every port is closed
        # and every real connection is refused.  Compare the config file
        # against the process too.
        $yaml = Get-Item $YamlPath -ErrorAction SilentlyContinue
        if ($yaml) {
            $procStart = $null
            try { $procStart = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction Stop).CreationDate } catch { }
            if ($procStart -and $yaml.LastWriteTime -gt $procStart.AddSeconds(1)) {
                Write-Host 'ser2net.yaml is newer than the running ser2net - restarting to pick it up...' -ForegroundColor Yellow
                Stop-Ser2net
                & $PSCommandPath start
                return
            }
        }

        $live = Get-UsbSerialDevices
        $reg  = Get-DevicesRegistry
        $merge = Merge-LiveDevices -Live $live -Registry $reg
        if ($merge.Changed) {
            Save-DevicesRegistry -Devices $merge.Devices
            $reg = $merge.Devices
        }

        $now = Get-CurrentMapping -Registry $reg -Live $live
        $before = ''
        if (Test-Path $StatePath) { try { $before = ((Get-Content -Raw -Encoding UTF8 $StatePath | ConvertFrom-Json).Mapping) } catch { } }

        if (-not $before -or $before -ne $now) {
            Write-Host 'device/COM mapping changed:' -ForegroundColor Yellow
            Write-Host ("  {0}" -f $now) -ForegroundColor Yellow
            Write-Host 'restarting to pick it up...' -ForegroundColor Yellow
            Stop-Ser2net
            & $PSCommandPath start
            return
        }

        Write-Host "no change - ser2net (pid $($proc.Id)) left untouched." -ForegroundColor Green
    }

    'status' {
        Write-Head 'process'
        $p = Get-Ser2netProc
        if ($p) {
            Write-Host "ser2net RUNNING  pid=$($p.Id)  started=$((Get-ProcStart $p))  mem=$([Math]::Round($p.WorkingSet64/1MB,1))MB"
        } else {
            Write-Host 'ser2net NOT running' -ForegroundColor Yellow
        }
        Write-Host "exe    : $(Find-Ser2netExe)"
        Write-Host "config : $YamlPath $(if (Test-Path $YamlPath) { "(generated $( (Get-Item $YamlPath).LastWriteTime ))" } else { '(missing)' })"

        Write-Head 'devices'
        $live = Get-UsbSerialDevices
        $reg  = Get-DevicesRegistry
        $rows = Resolve-Devices -Live $live -Registry $reg -Settings $settings
        Format-DevTable -Rows $rows

        Write-Head 'listeners'
        $lrows = foreach ($r in $rows) {
            $l = Get-ListeningPort -PortNumber $r.Port
            [pscustomobject]@{
                Alias = $r.Alias; TCP = $r.Port
                State = if ($l) { $l.State } else { 'closed' }
                Addr  = if ($l) { $l.LocalAddress } else { '-' }
            }
        }
        $lrows | Format-Table -AutoSize
    }

    'probe' {
        Write-Head 'banner probe (localhost)'
        $live = Get-UsbSerialDevices
        $reg  = Get-DevicesRegistry
        $rows = Resolve-Devices -Live $live -Registry $reg -Settings $settings
        $prows = foreach ($r in $rows) {
            $l = Get-ListeningPort -PortNumber $r.Port
            if (-not $l) {
                [pscustomobject]@{ Alias = $r.Alias; TCP = $r.Port; Listening = $false; Banner = '<not listening>'; Ok = $false }
            } else {
                $b = Test-PortBanner -BindIp (Get-ProbeIp $settings) -PortNumber $r.Port
                [pscustomobject]@{ Alias = $r.Alias; TCP = $r.Port; Listening = $b.Listening; Banner = $b.Banner; Ok = $b.Ok }
            }
        }
        $prows | Format-Table -AutoSize -Wrap
    }

    'logs' {
        $live = Get-UsbSerialDevices
        $reg  = Get-DevicesRegistry
        $dev = $reg | Where-Object { [int] $_.port -eq $Port } | Select-Object -First 1
        if (-not $dev) { Fail "port $Port is not in devices.json (run discover)" }
        $f = Join-Path $LogDir "dev-$($dev.alias).log"
        if (-not (Test-Path $f)) { Fail "no trace yet: $f (connect to it once first)" }
        Write-Host "tailing $f (ctrl-c to stop)" -ForegroundColor DarkGray
        Get-Content $f -Tail $(if ($Tail) { 40 } else { 200 })
    }

    'prune' {
        $keep = [int] $settings.traceKeepDays
        $cut = (Get-Date).AddDays(-$keep)
        $files = @(Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue)
        $old = @($files | Where-Object { $_.LastWriteTime -lt $cut })
        $bytes = ($old | Measure-Object -Property Length -Sum).Sum
        Write-Host "traces: $($files.Count) total, $($old.Count) older than $keep day(s), $([Math]::Round($bytes/1KB,1)) KB reclaimable"
        foreach ($f in $old) { Write-Host "  removing $($f.Name) ($([Math]::Round($f.Length/1KB,1)) KB)"; Remove-Item $f.FullName -Force }
        Write-Host 'done.'
    }

    'doctor' {
        $ok = $true

        Write-Head 'paths'
        foreach ($p in @($Root, $BinDir, $EtcDir, $LogDir, $DevicesPath)) {
            Write-Host ("{0,-58} {1}" -f $p, $(if (Test-Path $p) { 'ok' } else { 'MISSING' }))
            if (-not (Test-Path $p) -and $p -ne $DevicesPath) { $ok = $false }
        }

        Write-Head 'ser2net executable'
        $exe = Find-Ser2netExe
        if ($exe) { Write-Host $exe -ForegroundColor Green } else { Write-Host 'NOT FOUND - see README.md install step' -ForegroundColor Red; $ok = $false }

        Write-Head 'serialdev path form'
        Write-Host '.NET SerialPort rejects "\\.\COMn" in its constructor, so the open-probe can' -ForegroundColor DarkGray
        Write-Host 'only validate the plain "COMn" form. That is the form we emit.' -ForegroundColor DarkGray

        Write-Head 'devices'
        $live = Get-UsbSerialDevices
        $reg  = Get-DevicesRegistry
        if ($reg.Count -eq 0) {
            Write-Host 'registry empty - plug a USB-serial in and run: .\serial-hub.ps1 render' -ForegroundColor Red
            $ok = $false
        } else {
            $rows = Resolve-Devices -Live $live -Registry $reg -Settings $settings
            Format-DevTable -Rows $rows
            if (-not ($rows | Where-Object { $_.Usable })) { Write-Host 'no device currently usable (are they all plugged out / busy?)' -ForegroundColor Red; $ok = $false }
        }

        Write-Head 'rendered config'
        if (Test-Path $YamlPath) {
            $txt = [System.IO.File]::ReadAllText($YamlPath)
            $lb = ([regex]::Matches($txt, '\{\{')).Count
            Write-Host "ser2net.yaml present, unresolved placeholders: $lb"
            if ($lb -gt 0) { $ok = $false }
            ($txt -split "`n" | Select-String -Pattern '^\s+(enable|accepter|connector):' ) | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
        } else {
            Write-Host 'ser2net.yaml not generated yet - run: .\serial-hub.ps1 render' -ForegroundColor Yellow
        }

        Write-Head 'linux device table'
        Write-Host '  served live by query-server on port ' -NoNewline
        Write-Host "$($Settings.queryPort)" -ForegroundColor Cyan
        Write-Host '  (no snapshot file; clients ask this host on every run)' -ForegroundColor DarkGray
        if (Test-Path $DevConfPath) {
            Write-Warning "$DevConfPath still exists - it is a leftover from the old snapshot model. Delete it."
        }

        Write-Head 'process'
        $p = Get-Ser2netProc
        if ($p) { Write-Host "running, pid $($p.Id)" -ForegroundColor Green } else { Write-Host 'not running' -ForegroundColor Yellow }

        Write-Head 'listeners + banner'
        $rows2 = if (Test-Path $DevicesPath) {
            $reg2 = Get-DevicesRegistry
            $live2 = Get-UsbSerialDevices
            Resolve-Devices -Live $live2 -Registry $reg2 -Settings $settings
        } else { @() }
        $drows = foreach ($r in $rows2) {
            $l = Get-ListeningPort -PortNumber $r.Port
            if (-not $l) { [pscustomobject]@{ Alias = $r.Alias; TCP = $r.Port; Listening = $false; Banner = '<not listening>'; Ok = $false } }
            else { $b = Test-PortBanner -BindIp (Get-ProbeIp $settings) -PortNumber $r.Port; [pscustomobject]@{ Alias = $r.Alias; TCP = $r.Port; Listening = $b.Listening; Banner = $b.Banner; Ok = $b.Ok } }
        }
        $drows | Format-Table -AutoSize -Wrap

        Write-Head 'result'
        if ($ok) { Write-Host 'doctor: OK' -ForegroundColor Green } else { Write-Host 'doctor: problems found (see red above)' -ForegroundColor Yellow }
    }
}