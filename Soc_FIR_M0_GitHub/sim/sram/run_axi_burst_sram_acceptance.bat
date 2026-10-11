@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
if not defined VIVADO_BIN for %%I in (xvlog.bat) do set "VIVADO_BIN=%%~dp$PATH:I"
if not defined VIVADO_BIN (
  echo ERROR: Set VIVADO_BIN to the Vivado bin directory or add Vivado to PATH.
  exit /b 2
)
set "PROJECT_DIR=%SCRIPT_DIR%..\.."
set "BUILD_DIR=%SCRIPT_DIR%xsim_work_axi_burst_acceptance"

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
cd /d "%BUILD_DIR%"

call "%VIVADO_BIN%\xvlog.bat" --sv --work xil_defaultlib ^
  "%PROJECT_DIR%\rtl\sram\simple_sram_core.v" ^
  "%PROJECT_DIR%\rtl\sram\axi_burst_sram.v" ^
  "%SCRIPT_DIR%tb_axi_burst_sram.v"
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xelab.bat" xil_defaultlib.tb_axi_burst_sram_current ^
  -s tb_axi_burst_sram_current_behav --relax
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xsim.bat" tb_axi_burst_sram_current_behav -runall ^
  -log axi_burst_sram_acceptance.log
if errorlevel 1 exit /b 1

findstr /C:"Errors: 0" axi_burst_sram_acceptance.log >nul
if errorlevel 1 exit /b 1
findstr /C:"TEST PASS" axi_burst_sram_acceptance.log >nul
if errorlevel 1 exit /b 1
exit /b 0
