# probe-all.ps1 -- banner-read every live ser2net port (data-type, safe)
param([string] $Ip = '')

# Default to the address this install advertises (see probe-port.ps1).
if (-not $Ip) {
    $settings = Join-Path (Split-Path -Parent $PSScriptRoot) 'settings.json'
    try {
        $s = Get-Content -Raw -Encoding UTF8 $settings | ConvertFrom-Json
        $Ip = if ($s.advertiseIp) { [string] $s.advertiseIp } else { [string] $s.bindIp }
    } catch { }
    if (-not $Ip -or $Ip -eq '0.0.0.0') { $Ip = '127.0.0.1' }
}

$ports = 4000, 4001, 4002, 4003, 4006, 4007, 4008, 4009
foreach ($port in $ports) {
    $label = 'OFFLINE'
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($Ip, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000)) { throw 'connect timeout' }
        $c.EndConnect($iar)
        $s = $c.GetStream()
        $s.ReadTimeout = 4000
        $buf = New-Object byte[] 512
        $n = $s.Read($buf, 0, 512)
        $label = if ($n -gt 0) { [System.Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim() } else { '(empty banner)' }
        $c.Close()
    } catch { $label = "<error: $($_.Exception.Message)>" }
    Write-Host ("{0}: {1}" -f $port, $label)
}
'--- listeners -----------------------------------------------------------------'
# netstat, not Get-NetTCPConnection: the latter was observed hanging in
# hidden-window child PowerShell sessions on this machine.
netstat -ano | Select-String 'LISTENING' | Select-String ':40[0-9][0-9]\s'
