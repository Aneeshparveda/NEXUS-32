@echo off
rem NEXUS-32 integrated Basys 3 build on Windows.
rem Usage: RUN_VIVADO_BASYS3.bat [LANES] [MHZ]
rem   LANES = 4, 8, 16 or 32 (default 8)
rem   MHZ   = 100, 50 or 25  (default 100; 50/25 use an MMCM, for when 100 misses timing)
rem Uses the prebuilt PicoRV32 source and firmware image from the handoff
rem bundle (scripts/make_vivado_bundle.sh); no bash, RISC-V toolchain or git.
rem Set NEXUS32_FIRMWARE=smoke for the LED-only firmware (default: demo).
rem Set NEXUS32_NO_PAUSE=1 to skip the final pause (used by RUN_ALL.bat).
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%R in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fR"
set "LANES=%~1"
if "%LANES%"=="" set "LANES=8"
if not "%LANES%"=="4" if not "%LANES%"=="8" if not "%LANES%"=="16" if not "%LANES%"=="32" (
  echo ERROR: LANES must be 4, 8, 16 or 32; got "%LANES%".
  if not defined NEXUS32_NO_PAUSE pause
  exit /b 2
)
set "MHZ=%~2"
if "%MHZ%"=="" set "MHZ=100"
if not "%MHZ%"=="100" if not "%MHZ%"=="50" if not "%MHZ%"=="25" (
  echo ERROR: MHZ must be 100, 50 or 25; got "%MHZ%".
  if not defined NEXUS32_NO_PAUSE pause
  exit /b 2
)
set "BUILD_NAME=basys3_l%LANES%"
if not "%MHZ%"=="100" set "BUILD_NAME=basys3_l%LANES%_%MHZ%mhz"

call "%SCRIPT_DIR%find_vivado.bat"
if not defined VIVADO_CMD (
  echo =========================================================================
  echo ERROR: Vivado was not found on PATH, under C:\Xilinx\Vivado\ or C:\AMDDesignTools\.
  echo Open the Vivado Tcl Shell, or add Vivado's bin folder to PATH.
  echo =========================================================================
  if not defined NEXUS32_NO_PAUSE pause
  exit /b 2
)

if not exist "%ROOT_DIR%\vendor\picorv32\picorv32.v" (
  echo ERROR: vendor\picorv32\picorv32.v is missing. Unzip the handoff bundle made by
  echo        scripts/make_vivado_bundle.sh instead of a plain git clone.
  if not defined NEXUS32_NO_PAUSE pause
  exit /b 2
)
if not exist "%ROOT_DIR%\firmware\nexus32_demo.hex" (
  echo ERROR: firmware\nexus32_demo.hex is missing. Unzip the handoff bundle made by
  echo        scripts/make_vivado_bundle.sh instead of a plain git clone.
  if not defined NEXUS32_NO_PAUSE pause
  exit /b 2
)

set "OUT_DIR=%ROOT_DIR%\results\vivado\%BUILD_NAME%"
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
set "NEXUS32_INPUTS=prebuilt"

echo Using: %VIVADO_CMD%
echo Building top_basys3 with LANES=%LANES% at %MHZ% MHz into %OUT_DIR%
call "%VIVADO_CMD%" -mode batch -log "%OUT_DIR%\vivado.log" -journal "%OUT_DIR%\vivado.jou" -source "%ROOT_DIR%\vivado\build_basys3.tcl" -tclargs "%OUT_DIR%" %LANES% %MHZ%
if errorlevel 1 goto :failed

echo.
echo =========================================================================
echo SUCCESS: LANES=%LANES% %MHZ% MHz board build finished.
echo   Summary  : %OUT_DIR%\build_summary.md
echo   Metrics  : %OUT_DIR%\metrics.txt
echo   Bitstream: %OUT_DIR%\top_basys3.bit
echo =========================================================================
if not defined NEXUS32_NO_PAUSE pause
exit /b 0

:failed
echo.
echo =========================================================================
echo LANES=%LANES% %MHZ% MHz board build FAILED. Open %OUT_DIR%\build_summary.md and
echo %OUT_DIR%\vivado.log to see which stage failed.
echo =========================================================================
if not defined NEXUS32_NO_PAUSE pause
exit /b 1
