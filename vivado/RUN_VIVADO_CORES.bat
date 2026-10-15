@echo off
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%..\"
set "VIVADO_CMD="

for /f "delims=" %%V in ('where vivado 2^>nul') do if not defined VIVADO_CMD set "VIVADO_CMD=%%V"

if not defined VIVADO_CMD (
  for /d %%V in ("C:\Xilinx\Vivado\*") do if exist "%%~fV\bin\vivado.bat" set "VIVADO_CMD=%%~fV\bin\vivado.bat"
)

if not defined VIVADO_CMD (
  echo =========================================================================
  echo ERROR: Vivado was not found on PATH or under C:\Xilinx\Vivado\.
  echo Please open the Vivado Tcl Shell or set your Vivado bin path.
  echo =========================================================================
  pause
  exit /b 2
)

echo Using: %VIVADO_CMD%
call "%VIVADO_CMD%" -version
if errorlevel 1 goto :failed

echo Running NEXUS-32 FIR Core Characterization Sweep...
call "%VIVADO_CMD%" -mode batch -source "%SCRIPT_DIR%run_core_characterization.tcl" -tclargs "%ROOT_DIR%results\vivado_core"
if errorlevel 1 goto :failed

echo.
echo =========================================================================
echo SUCCESS: Characterization complete.
echo Summary reports are in:
echo   %ROOT_DIR%results\vivado_core\characterization_summary.md
echo   %ROOT_DIR%results\vivado_core\characterization_summary.csv
echo =========================================================================
pause
exit /b 0

:failed
echo.
echo =========================================================================
echo Vivado characterization returned an error. Inspect the run logs.
echo =========================================================================
pause
exit /b 1
