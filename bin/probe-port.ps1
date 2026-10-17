# probe-port.ps1 -- one banner read against a ser2net port (data-type, safe)
param([string] $Ip = '172.16.66.163', [int] $Port = 4000)
$c = New-Object System.Net.Sockets.TcpClient
$c.Connect($Ip, $Port)
$s = $c.GetStream()
$s.ReadTimeout = 4000
$buf = New-Object byte[] 256
$n = $s.Read($buf, 0, 256)
$b = [System.Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Max(0, $n)).Trim()
Write-Host "banner: $b"
$c.Close()