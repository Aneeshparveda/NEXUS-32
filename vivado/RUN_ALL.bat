@echo off
rem NEXUS-32 one-click Vivado run (Windows). Leave it running; it continues
rem past a failed step and records every step's exit code.
rem   1. Board build LANES=4  @100 MHz  (fastest path to a first bitstream)
rem   2. Board build LANES=8  @100 MHz  (board default)
rem   3. Board build LANES=8  @50 MHz   only if step 2 did not meet timing
rem   4. Core characterization sweep    (each engine alone; the longest step)
rem   5. Evidence collection            (results\evidence + nexus32-evidence.zip)
rem Then: PROGRAM_BOARD.bat, READ_UART.bat, COLLECT_EVIDENCE.bat.
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%R in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fR"
set "NEXUS32_NO_PAUSE=1"
if not exist "%ROOT_DIR%\results" mkdir "%ROOT_DIR%\results"
set "LOG=%ROOT_DIR%\results\run_all_log.txt"

call "%SCRIPT_DIR%find_vivado.bat"
if not defined VIVADO_CMD (
  echo ERROR: Vivado was not found on PATH, under C:\Xilinx\Vivado\ or C:\AMDDesignTools\.
  pause
  exit /b 2
)

> "%LOG%" echo NEXUS-32 RUN_ALL started %DATE% %TIME%
>>"%LOG%" echo Vivado: %VIVADO_CMD%
>>"%LOG%" echo Root: %ROOT_DIR%

call :step "board LANES=4 at 100 MHz" "%SCRIPT_DIR%RUN_VIVADO_BASYS3.bat" 4 100
call :step "board LANES=8 at 100 MHz" "%SCRIPT_DIR%RUN_VIVADO_BASYS3.bat" 8 100

findstr /x /c:"TIMING_MET=YES" "%ROOT_DIR%\results\vivado\basys3_l8\metrics.txt" >nul 2>&1
if errorlevel 1 (
  call :step "board LANES=8 at 50 MHz (100 MHz did not meet timing)" "%SCRIPT_DIR%RUN_VIVADO_BASYS3.bat" 8 50
) else (
  >>"%LOG%" echo [%TIME%] SKIP  board LANES=8 at 50 MHz: 100 MHz met timing
)

call :step "core characterization sweep" "%SCRIPT_DIR%RUN_VIVADO_CORES.bat"
>>"%LOG%" echo NEXUS-32 RUN_ALL builds finished %DATE% %TIME%
call :step "collect evidence" "%SCRIPT_DIR%COLLECT_EVIDENCE.bat"

echo.
echo =========================================================================
echo RUN_ALL finished. Step results:
type "%LOG%"
echo.
echo Next (board connected and switched on):
echo   1. PROGRAM_BOARD.bat      programs the best build
echo   2. READ_UART.bat          saves the board's report
echo   3. COLLECT_EVIDENCE.bat   refreshes results\evidence and nexus32-evidence.zip
echo Without a board, send %ROOT_DIR%\nexus32-evidence.zip as it is.
echo =========================================================================
pause
exit /b 0

:step
set "STEP_NAME=%~1"
echo.
echo ===== %STEP_NAME% =====
>>"%LOG%" echo [%TIME%] START %STEP_NAME%
call %2 %3 %4
set "STEP_RC=%ERRORLEVEL%"
>>"%LOG%" echo [%TIME%] END   %STEP_NAME% exit=%STEP_RC%
exit /b 0
