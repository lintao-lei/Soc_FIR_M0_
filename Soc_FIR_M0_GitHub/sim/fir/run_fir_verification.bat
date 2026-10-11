@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
if not defined VIVADO_BIN for %%I in (xvlog.bat) do set "VIVADO_BIN=%%~dp$PATH:I"
if not defined VIVADO_BIN (
  echo ERROR: Set VIVADO_BIN to the Vivado bin directory or add Vivado to PATH.
  exit /b 2
)
set "PROJECT_DIR=%SCRIPT_DIR%..\.."
set "BUILD_DIR=%SCRIPT_DIR%xsim_work"

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
cd /d "%BUILD_DIR%"

call "%VIVADO_BIN%\xvlog.bat" --work xil_defaultlib ^
  "%PROJECT_DIR%\rtl\fir\fir_81tap_core.v" ^
  "%PROJECT_DIR%\rtl\fir\fir_81tap_axi.v" ^
  "%PROJECT_DIR%\rtl\fir\axi_fir_data.v" ^
  "%PROJECT_DIR%\rtl\fir\fir_subsystem.v"
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xvlog.bat" --sv --work xil_defaultlib ^
  "%SCRIPT_DIR%tb_fir_subsystem.sv"
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xelab.bat" xil_defaultlib.tb_fir_subsystem ^
  -s tb_fir_subsystem_behav -debug typical
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xsim.bat" tb_fir_subsystem_behav -runall ^
  -log fir_verification.log
exit /b %errorlevel%

