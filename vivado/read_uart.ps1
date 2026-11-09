# NEXUS-32: capture the board's UART report (115200 8N1) to a text file.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File read_uart.ps1 [-Port COM4] [-Seconds 15] [-Out path]
# The demo firmware re-prints its report about every 1.6 s, so a 15 s capture
# holds several complete copies. Press the board's centre button during the
# capture to also record a fresh boot.
param(
    [string]$Port = "",
    [int]$Seconds = 15,
    [string]$Out = ""
)
$ErrorActionPreference = "Stop"
if (-not $Out) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "results\evidence\uart_log.txt"
}
$ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique
if (-not $Port) {
    if ($ports.Count -eq 1) {
        $Port = $ports[0]
    } elseif ($ports.Count -eq 0) {
        Write-Host "ERROR: no COM port found. Connect the Basys 3 by USB, switch it on, and check Device Manager > Ports (COM & LPT)."
        exit 2
    } else {
        Write-Host "Available COM ports: $($ports -join ', ')"
        Write-Host "The Basys 3 UART is the 'USB Serial Port (COMx)' entry in Device Manager > Ports."
        $Port = Read-Host "COM port to read (for example COM4)"
    }
}
Write-Host "Reading $Port at 115200 8N1 for $Seconds s ..."
$serial = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$serial.ReadTimeout = 500
$serial.Open()
$text = New-Object System.Text.StringBuilder
$deadline = (Get-Date).AddSeconds($Seconds)
try {
    while ((Get-Date) -lt $deadline) {
        $chunk = $serial.ReadExisting()
        if ($chunk) {
            Write-Host -NoNewline $chunk
            [void]$text.Append($chunk)
        }
        Start-Sleep -Milliseconds 100
    }
} finally {
    $serial.Close()
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
Set-Content -Path $Out -Value $text.ToString() -Encoding Ascii
Write-Host ""
Write-Host "Saved UART log: $Out"
if ($text.ToString().Contains("NEXUS32 RESULT: PASS")) {
    Write-Host "Board verdict: PASS"
} elseif ($text.ToString().Contains("NEXUS32 RESULT: FAIL")) {
    Write-Host "Board verdict: FAIL"
} else {
    Write-Host "Board verdict: no RESULT line received (wrong COM port, board not programmed, or press the centre button and retry)."
}
