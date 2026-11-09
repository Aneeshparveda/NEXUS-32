@echo off
rem Program the connected Basys 3 with the best board build (or the build
rem named as the first argument, e.g. PROGRAM_BOARD.bat basys3_l4).
rem Board: USB cable in the PROG/UART port, power switch ON.
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%R in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fR"

call "%SCRIPT_DIR%find_vivado.bat"
if not defined VIVADO_CMD (
  echo ERROR: Vivado was not found on PATH, under C:\Xilinx\Vivado\ or C:\AMDDesignTools\.
  pause
  exit /b 2
)

if not exist "%ROOT_DIR%\results" mkdir "%ROOT_DIR%\results"
set "TCLARGS="
if not "%~1"=="" set "TCLARGS=-tclargs %~1"
pushd "%ROOT_DIR%"
call "%VIVADO_CMD%" -mode batch -nojournal -log "%ROOT_DIR%\results\program_board.log" -source "%SCRIPT_DIR%program_board.tcl" %TCLARGS%
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
  echo.
  echo ERROR: programming failed. See %ROOT_DIR%\results\program_board.log
  pause
  exit /b 1
)
echo.
echo Board programmed. Check LD0 and LD2 on, LD3 off. Next: READ_UART.bat
pause
exit /b 0
