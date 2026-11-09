@echo off
rem Sets VIVADO_CMD to vivado.bat for the caller (no setlocal on purpose).
rem Order: PATH, C:\Xilinx\Vivado\<ver>, C:\AMDDesignTools\<ver>\Vivado.
rem Looks up vivado.bat explicitly: Vivado's bin folder also holds an
rem extensionless Linux launcher named "vivado" that cmd cannot run.
set "VIVADO_CMD="
for /f "delims=" %%V in ('where vivado.bat 2^>nul') do if not defined VIVADO_CMD set "VIVADO_CMD=%%V"
if not defined VIVADO_CMD (
  for /d %%V in ("C:\Xilinx\Vivado\*") do if exist "%%~fV\bin\vivado.bat" set "VIVADO_CMD=%%~fV\bin\vivado.bat"
)
if not defined VIVADO_CMD (
  for /d %%V in ("C:\AMDDesignTools\*") do if exist "%%~fV\Vivado\bin\vivado.bat" set "VIVADO_CMD=%%~fV\Vivado\bin\vivado.bat"
)
exit /b 0
