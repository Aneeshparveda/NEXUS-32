@echo off
rem Collect every Vivado/board result into results\evidence\EVIDENCE.md and
rem zip it as nexus32-evidence.zip in the repository root. Safe to rerun.
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%R in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fR"

call "%SCRIPT_DIR%find_vivado.bat"
if not defined VIVADO_CMD (
  echo ERROR: Vivado was not found on PATH, under C:\Xilinx\Vivado\ or C:\AMDDesignTools\.
  if not defined NEXUS32_NO_PAUSE pause
  exit /b 2
)

call "%VIVADO_CMD%" -mode batch -nojournal -nolog -source "%SCRIPT_DIR%collect_evidence.tcl" -tclargs "%ROOT_DIR%"
if errorlevel 1 goto :failed

if exist "%ROOT_DIR%\nexus32-evidence.zip" del /q "%ROOT_DIR%\nexus32-evidence.zip"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path '%ROOT_DIR%\results\evidence\*' -DestinationPath '%ROOT_DIR%\nexus32-evidence.zip' -Force"
if errorlevel 1 goto :failed

echo.
echo =========================================================================
echo Evidence summary: %ROOT_DIR%\results\evidence\EVIDENCE.md
echo Send this file:   %ROOT_DIR%\nexus32-evidence.zip
echo =========================================================================
if not defined NEXUS32_NO_PAUSE pause
exit /b 0

:failed
echo ERROR: evidence collection failed; see the messages above.
if not defined NEXUS32_NO_PAUSE pause
exit /b 1
