# direct-com-open.ps1 -- try opening a COM directly (no DTR/RTS asserts)
param([string[]] $Coms = @('COM99', 'COM148'))
foreach ($com in $Coms) {
    $sp = New-Object System.IO.Ports.SerialPort
    $sp.PortName = $com
    $sp.BaudRate = 115200
    $sp.DtrEnable = $false
    $sp.RtsEnable = $false
    $sp.ReadTimeout = 2000
    $sp.WriteTimeout = 2000
    try {
        $sp.Open()
        Write-Host ("{0}: OPEN OK (driver fine)" -f $com) -ForegroundColor Green
    } catch {
        Write-Host ("{0}: open FAILED: {1}" -f $com, $_.Exception.Message) -ForegroundColor Red
    } finally {
        try { if ($sp.IsOpen) { $sp.DtrEnable = $false; $sp.RtsEnable = $false; $sp.Close() } } catch { }
        try { $sp.Dispose() } catch { }
    }
}