@echo off
rem NEXUS-32 out-of-context characterization sweep (each FIR engine alone at
rem LANES 4/8/16/32, plus the selector) on Windows.
rem Set NEXUS32_NO_PAUSE=1 to skip the final pause (used by RUN_ALL.bat).
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%R in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fR"

call "%SCRIPT_DIR%find_vivado.bat"
if not defined VIVADO_CMD (
  echo =========================================================================
  echo ERROR: Vivado was not found on PATH, under C:\Xilinx\Vivado\ or C:\AMDDesignTools\.
  echo Open the Vivado Tcl Shell or set your Vivado bin path.
  echo =========================================================================
  if not defined NEXUS32_NO_PAUSE pause
  exit /b 2
)

set "OUT_DIR=%ROOT_DIR%\results\vivado_core"
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
echo Using: %VIVADO_CMD%
call "%VIVADO_CMD%" -version
if errorlevel 1 goto :failed

echo Running NEXUS-32 FIR Core Characterization Sweep...
call "%VIVADO_CMD%" -mode batch -log "%OUT_DIR%\vivado.log" -journal "%OUT_DIR%\vivado.jou" -source "%SCRIPT_DIR%run_core_characterization.tcl" -tclargs "%OUT_DIR%"
if errorlevel 1 goto :failed

echo.
echo =========================================================================
echo SUCCESS: Characterization complete.
echo Summary reports are in:
echo   %OUT_DIR%\characterization_summary.md
echo   %OUT_DIR%\characterization_summary.csv
echo =========================================================================
if not defined NEXUS32_NO_PAUSE pause
exit /b 0

:failed
echo.
echo =========================================================================
echo Vivado characterization returned an error. Inspect %OUT_DIR%\vivado.log
echo and %OUT_DIR%\characterization_summary.md (failed cases are listed there).
echo =========================================================================
if not defined NEXUS32_NO_PAUSE pause
exit /b 1
