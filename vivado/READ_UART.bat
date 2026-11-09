@echo off
rem Capture the board's UART report for 15 s into results\evidence\uart_log.txt.
rem Usage: READ_UART.bat [COMx]   (auto-detected when only one COM port exists)
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%R in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fR"
set "PORT_ARG="
if not "%~1"=="" set "PORT_ARG=-Port %~1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%read_uart.ps1" %PORT_ARG% -Seconds 15 -Out "%ROOT_DIR%\results\evidence\uart_log.txt"
echo.
echo Next: COLLECT_EVIDENCE.bat
pause
exit /b 0
