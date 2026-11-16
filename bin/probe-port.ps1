# probe-port.ps1 -- one banner read against a ser2net port (data-type, safe)
param([string] $Ip = '', [int] $Port = 4000)

# Default to the address this install advertises, so the tool keeps working
# after the package is moved to a machine with a different IP.
if (-not $Ip) {
    $settings = Join-Path (Split-Path -Parent $PSScriptRoot) 'settings.json'
    try {
        $s = Get-Content -Raw -Encoding UTF8 $settings | ConvertFrom-Json
        $Ip = if ($s.advertiseIp) { [string] $s.advertiseIp } else { [string] $s.bindIp }
    } catch { }
    if (-not $Ip -or $Ip -eq '0.0.0.0') { $Ip = '127.0.0.1' }
}

$c = New-Object System.Net.Sockets.TcpClient
$c.Connect($Ip, $Port)
$s = $c.GetStream()
$s.ReadTimeout = 4000
$buf = New-Object byte[] 256
$n = $s.Read($buf, 0, 256)
$b = [System.Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Max(0, $n)).Trim()
Write-Host "banner: $b"
$c.Close()
