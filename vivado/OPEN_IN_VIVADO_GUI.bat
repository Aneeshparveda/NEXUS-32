@echo off
rem Open a routed board build in the Vivado GUI for screenshots
rem (Window > Device for the floorplan; Reports > Report Utilization/Timing).
rem Usage: OPEN_IN_VIVADO_GUI.bat [build]   (default basys3_l8)
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%R in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fR"
set "BUILD=%~1"
if "%BUILD%"=="" set "BUILD=basys3_l8"
set "DCP=%ROOT_DIR%\results\vivado\%BUILD%\reports\post_implementation\top_basys3_post_implementation.dcp"
if not exist "%DCP%" (
  echo ERROR: no routed checkpoint at %DCP%
  pause
  exit /b 2
)
call "%SCRIPT_DIR%find_vivado.bat"
if not defined VIVADO_CMD (
  echo ERROR: Vivado was not found on PATH, under C:\Xilinx\Vivado\ or C:\AMDDesignTools\.
  pause
  exit /b 2
)
start "" "%VIVADO_CMD%" "%DCP%"
exit /b 0
