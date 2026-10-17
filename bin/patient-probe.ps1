# patient-probe.ps1 -- long-timeout banner read on ONE port (data-type, safe)
param([int] $Port = 4000, [int] $TimeoutMs = 15000)
$c = New-Object System.Net.Sockets.TcpClient
$c.Connect('172.16.66.163', $Port)
$s = $c.GetStream()
$s.ReadTimeout = $TimeoutMs
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $buf = New-Object byte[] 512
    $n = $s.Read($buf, 0, 512)
    $txt = if ($n -gt 0) { [System.Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim() } else { '(empty)' }
    Write-Host ("port {0}: [{1}ms] {2}" -f $Port, $sw.ElapsedMilliseconds, $txt)
} catch {
    Write-Host ("port {0}: <{1}ms error: {2}>" -f $Port, $sw.ElapsedMilliseconds, $_.Exception.Message)
} finally {
    $c.Close()
}