# probe-all.ps1 -- banner-read every live ser2net port (data-type, safe)
$ports = 4000, 4001, 4002, 4003, 4006, 4007, 4008, 4009
foreach ($port in $ports) {
    $label = 'OFFLINE'
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('172.16.66.163', $port, $null, $null)
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
'--- listeners ---'
Get-NetTCPConnection -State Listen -LocalPort 4000,4001,4002,4003,4006,4007,4008,4009 -ErrorAction SilentlyContinue |
    Select-Object LocalPort, OwningProcess | Sort-Object LocalPort | Format-Table -AutoSize
'--- ser2net processes (expect 1) ---'
Get-CimInstance Win32_Process -Filter "Name='ser2net.exe'" | Select-Object ProcessId, CreationDate | Format-Table -AutoSize