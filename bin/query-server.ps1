<#
    query-server.ps1 - serve the LIVE device table over TCP.

    Why this exists
    ---------------
    linux\devices.conf used to be the only thing the Linux side knew about the
    hub.  It is a render snapshot that only reaches the box when somebody runs
    `serial-hub push`, so an unplugged adapter stays listed there forever and a
    newly plugged one stays invisible until the next manual push.

    This listener is the authoritative, pull-based answer to "which serial
    devices do you have right now?".  It re-enumerates USB per request, so the
    answer reflects reality within milliseconds of a replug - no push, no
    polling loop, no /usr/bin writes, no sudo, no SSH keys.

    Protocol
    --------
    Plain TCP.  The client connects, sends one line, and the server replies with
    a `devices.conf`-compatible table (same format console.sh already parses),
    then closes.  Requests:

        devices            the device table (alias label host port, one per line)
        ping               one status line - is the hub alive and what is it
                            reachable as (host, advertised address, counts)
        <anything else>    treated as `devices` - it is a 6-line script, not a
                            protocol; strictness would only break future clients.

    The table only lists devices that are plugged in RIGHT NOW: absent ones are
    simply not mentioned.  A reply with no device lines (just the two comment
    headers) is a valid, complete answer meaning "nothing plugged in" - the
    client shows the source as live and lists nothing, rather than silently
    falling back to a stale snapshot.

    If devices.json cannot be read, the connection is closed WITHOUT a reply
    instead of returning an empty table: "nothing plugged in" and "registry
    unreadable" must never look the same to the client.

    Deliberately read-only and cheap: it never opens a COM port.  Opening the
    real serial device is ser2net's job (port 4000+); a TCP query that touched
    COM would risk the "Device open failure: Permission denied" quirk that
    ptybridge.py already has to work around.

    Started automatically by autostart.ps1 (as SYSTEM, at boot) and restarted by
    that same loop if it ever dies.  Test by hand:
        powershell -ExecutionPolicy Bypass -File C:\ser2net\bin\query-server.ps1 -Once
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [int]    $Port = 0,        # 0 = take from settings.json
    [string] $Bind = $null,
    [switch] $Once             # handle a single request then exit (self-test)
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot

$SettingsPath = Join-Path $Root 'settings.json'
$DevicesPath  = Join-Path $Root 'devices.json'
$LogPath      = Join-Path $Root 'logs\query-server.log'

if (-not (Test-Path (Split-Path $LogPath))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
}

function Say {
    param([string] $m)
    Add-Content -Path $LogPath -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

# ---------------------------------------------------------------- config
# settings.json + devices.json are re-read on EVERY request, not cached at
# startup.  Both are small (a few hundred bytes) and requests are rare, so the
# cost is nil, while the payoff is that registering a new device
# (`serial-hub discover`) or changing advertiseIp takes effect immediately -
# no restart of this server, and no chance of it answering from a config that
# belongs to the previous boot.
function Get-Config {
    $settings = $null
    try {
        if (Test-Path $SettingsPath) {
            $settings = Get-Content -Raw -Encoding UTF8 $SettingsPath | ConvertFrom-Json
        }
    } catch { $settings = $null }

    $reg = @()
    $regErr = $null
    if (Test-Path $DevicesPath) {
        # Retry: serial-hub.ps1 replaces the file atomically, but an external
        # editor or a backup tool can still hold it for a moment.
        for ($i = 0; $i -lt 4; $i++) {
            try {
                $reg = @((Get-Content -Raw -Encoding UTF8 $DevicesPath | ConvertFrom-Json).devices) |
                       Where-Object { $null -ne $_ }
                $regErr = $null
                break
            } catch {
                $regErr = $_.Exception.Message
                Start-Sleep -Milliseconds 120
            }
        }
    }

    [pscustomobject]@{
        Settings      = $settings
        Registry      = @($reg)
        RegistryError = $regErr
    }
}

$cfg = Get-Config
if ($Port -le 0) {
    $Port = if ($cfg.Settings -and $cfg.Settings.queryPort) { [int] $cfg.Settings.queryPort } else { 4099 }
}
if (-not $Bind) {
    $Bind = if ($cfg.Settings -and $cfg.Settings.queryBind) { [string] $cfg.Settings.queryBind } else { '0.0.0.0' }
}
if ($Port -le 0) {
    Say 'query-server: queryPort is 0 - disabled, exiting.'
    exit 0
}

# The advertised host: must be a connectable address, never the 0.0.0.0 bind.
function Get-AdvIp($settings, $fallbackBind) {
    $adv = $fallbackBind
    if ($settings -and $settings.advertiseIp) { $adv = [string] $settings.advertiseIp }
    if ($adv -eq '0.0.0.0' -or $adv -eq '::') { $adv = $env:COMPUTERNAME }
    return $adv
}

$AdvIp = Get-AdvIp $cfg.Settings $Bind
Say "query-server: starting on ${Bind}:${Port}, advertising $AdvIp, $($cfg.Registry.Count) registered device(s)"

# ---------------------------------------------------------------- enumerator
# Deliberately NOT Get-CimInstance Win32_PnPEntity: that spawns a WMI provider
# process per request (~0.5-1 s, and it serialises behind other WMI users).
# Get-PnpDevice is in-box and returns in milliseconds; we key the registry off
# the PnP DeviceID (InstanceId) exactly like the WMI path does.
function Get-LiveComDevices {
    $out = @()
    try {
        $devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                  Where-Object {
                      $_.Class -eq 'Ports' -and
                      ($_.InstanceId -like 'USB\*' -or $_.InstanceId -like 'FTDIBUS\*')
                  })
    } catch { return ,@() }

    foreach ($d in $devs) {
        $com = $null
        # FriendlyName looks like "USB-Enhanced-SERIAL-A CH344 (COM6)".
        if ($d.FriendlyName -match '\(COM(\d+)\)') { $com = [int] $Matches[1] }
        if ($null -eq $com) { continue }
        $label = ($d.FriendlyName -replace '\(COM\d+\)\s*$', '').Trim()
        $out += [pscustomobject]@{
            Fingerprint = $d.InstanceId
            Com         = $com
            Name        = $label
        }
    }
    return ,$out
}

# Build the device table.  Only plugged-in devices appear; the registry supplies
# the alias/label/port (the stable identity) and the live list decides presence.
function Get-DeviceTable($registry, $advIp) {
    $live = Get-LiveComDevices
    $lines = @()
    $present = 0
    foreach ($r in $registry) {
        if ($null -eq $r) { continue }
        $lv = $live | Where-Object { $null -ne $_ -and $_.Fingerprint -eq $r.fingerprint } | Select-Object -First 1
        if ($null -eq $lv) { continue }        # absent devices are simply not listed
        $label = [string] $r.label
        if (-not $label) { $label = [string] $r.alias }
        $lines += "{0,-6} {1,-28} {2} {3}" -f $r.alias, $label, $advIp, $r.port
        $present++
    }
    return [pscustomobject]@{ Lines = $lines; Present = $present; Live = $live.Count }
}

# ------------------------------------------------------------------- server
$listener = $null
try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($Bind), $Port)
    $listener.Start()
} catch {
    Say "query-server: cannot listen on ${Bind}:${Port} - $($_.Exception.Message)"
    exit 1
}

Say 'query-server: listening (autostart.ps1 restarts it if it dies)'

$serveOne = {
    param($client)
    try {
        $stream = $client.GetStream()
        # A real client sends its one-word request immediately.  Keep this
        # timeout short: the accept loop is single-threaded, so a stray
        # zero-byte connection (port probe, health check) would otherwise hold
        # every other client for the full three seconds - which is exactly the
        # "first --list says did not answer, second one works" symptom.  On
        # timeout we still fall through and answer as `devices`.
        $stream.ReadTimeout = 800
        $stream.WriteTimeout = 3000
        try { $client.NoDelay = $true } catch { }

        # Read the request word.  Anything unrecognised is treated as `devices`.
        $req = ''
        $buf = New-Object byte[] 512
        try {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { $req = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n) }
        } catch { }
        $req = (($req -split "`r?`n")[0]).Trim().ToLowerInvariant()

        # Fresh config per request (see Get-Config).
        $c = Get-Config
        # An unreadable registry must NOT be answered with an empty table: the
        # client cannot tell that apart from "nothing is plugged in" and shows a
        # perfectly successful, completely wrong --list.  Closing without a
        # reply makes the client report "hub did not answer", which is true.
        if ($c.RegistryError) {
            throw "devices.json unreadable - refusing to answer with an empty table: $($c.RegistryError)"
        }
        $advIp = Get-AdvIp $c.Settings $Bind

        if ($req -eq 'ping') {
            $t = Get-DeviceTable $c.Registry $advIp
            $body = @(
                '# hub ok from {0}  advertise={1}  bind={2}:{3}  registered={4}  live={5}  ports-in-use={6}' -f
                    [System.Net.Dns]::GetHostName(), $advIp, $Bind, $Port, $c.Registry.Count, $t.Live, $t.Present
            )
        } else {
            $t = Get-DeviceTable $c.Registry $advIp
            $body = @(
                "# live device table from $([System.Net.Dns]::GetHostName())"
                "# generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - query-server.ps1"
            ) + $t.Lines
        }

        $payload = (($body -join "`n") + "`n")
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        Say "query-server: request failed: $($_.Exception.Message)"
    } finally {
        try { $client.Close() } catch { }
    }
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        & $serveOne $client
        if ($Once) { break }
    }
} catch [System.Net.Sockets.SocketException] {
    Say "query-server: socket error - $($_.Exception.Message)"
} finally {
    try { $listener.Stop() } catch { }
    Say 'query-server: stopped'
}