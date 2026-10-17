# demo-2-readers.ps1 -- prove two TCP readers coexist on one ser2net port
# (requires ser2net.yaml to have max-connections >= 2 / kickolduser false)
$ErrorActionPreference = 'Stop'
$addr = '172.16.66.163'
$port = 4000

function New-Reader([string] $tag) {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect($addr, $port)
    $s = $c.GetStream()
    $s.ReadTimeout = 4000
    $buf = New-Object byte[] 256
    $n = $s.Read($buf, 0, 256)
    $banner = [System.Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Max(0, $n)).Trim()
    [pscustomobject]@{ Tag = $tag; Client = $c; Stream = $s; Banner = $banner; N = $n }
}

try {
    $r1 = New-Reader 'reader1'
    Write-Host "reader1: connected, banner=$($r1.Banner)" -ForegroundColor Green
    Start-Sleep -Milliseconds 800

    $r2 = New-Reader 'reader2'
    Write-Host "reader2: connected, banner=$($r2.Banner)" -ForegroundColor Green
    Start-Sleep -Milliseconds 800

    # if reader1 had been kicked (old max-connections:1 behavior), this read
    # would throw/return 0 immediately. A clean timeout means it is still alive.
    $alive1 = $true
    try {
        $b = New-Object byte[] 64
        [void]$r1.Stream.Read($b, 0, 64)   # board is silent -> clean timeout = alive
    } catch [System.IO.IOException] {
        if ($_.Exception.InnerException -and $_.Exception.InnerException.Message -match 'closed|reset') { $alive1 = $false }
        # else: timeout -> still alive
    } catch { $alive1 = $false }

    $alive2 = ($r2.Client.Connected -and $r1.Client.Connected)

    Write-Host "reader1 alive after reader2 joined : $alive1" -ForegroundColor $(if ($alive1) { 'Green' } else { 'Red' })
    Write-Host "reader2 alive                      : $alive2" -ForegroundColor $(if ($alive2) { 'Green' } else { 'Red' })

    # bonus: a THIRD connection should NOT get a normal attach (max-connections: 2)
    $third = $null
    try {
        $third = New-Reader 'reader3'
        Write-Host "reader3: unexpected - got banner: $($third.Banner)" -ForegroundColor Yellow
    } catch {
        Write-Host "reader3: rejected as expected ($($_.Exception.Message))" -ForegroundColor Yellow
    }

    Write-Host ''
    if ($alive1 -and $alive2) { Write-Host 'RESULT: two readers coexist on the same port - OK' -ForegroundColor Green }
    else                      { Write-Host 'RESULT: coexistence FAILED' -ForegroundColor Red }
} finally {
    foreach ($r in @($r1, $r2, $third)) { if ($r) { $r.Client.Close() } }
    Write-Host 'connections closed.'
}