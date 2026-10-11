@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
if not defined VIVADO_BIN for %%I in (xvlog.bat) do set "VIVADO_BIN=%%~dp$PATH:I"
if not defined VIVADO_BIN (
  echo ERROR: Set VIVADO_BIN to the Vivado bin directory or add Vivado to PATH.
  exit /b 2
)
set "PROJECT_DIR=%SCRIPT_DIR%..\.."
set "BUILD_DIR=%SCRIPT_DIR%xsim_work_arbiter_write_fairness"

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
cd /d "%BUILD_DIR%"

call "%VIVADO_BIN%\xvlog.bat" --sv --work xil_defaultlib ^
  "%PROJECT_DIR%\rtl\interconnect\read_arbiter.v" ^
  "%PROJECT_DIR%\rtl\interconnect\write_arbiter.v" ^
  "%PROJECT_DIR%\rtl\interconnect\arbiter.v" ^
  "%SCRIPT_DIR%tb_arbiter_write_fairness_stress.sv"
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xelab.bat" xil_defaultlib.tb_arbiter_write_fairness_stress ^
  -s tb_arbiter_write_fairness_stress_behav --relax
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xsim.bat" tb_arbiter_write_fairness_stress_behav -runall ^
  -log arbiter_write_fairness_stress.log
if errorlevel 1 exit /b 1

findstr /C:"TEST PASS:" arbiter_write_fairness_stress.log >nul
if errorlevel 1 exit /b 1
exit /b 0
