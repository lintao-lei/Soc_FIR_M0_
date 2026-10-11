@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
if not defined VIVADO_BIN for %%I in (xvlog.bat) do set "VIVADO_BIN=%%~dp$PATH:I"
if not defined VIVADO_BIN (
  echo ERROR: Set VIVADO_BIN to the Vivado bin directory or add Vivado to PATH.
  exit /b 2
)
set "PROJECT_DIR=%SCRIPT_DIR%..\.."
set "BUILD_DIR=%SCRIPT_DIR%xsim_work_dma_mixed16"

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
cd /d "%BUILD_DIR%"

call "%VIVADO_BIN%\xvlog.bat" --sv --work xil_defaultlib ^
  "%PROJECT_DIR%\rtl\dma\dma_carry.v" ^
  "%PROJECT_DIR%\rtl\dma\dma6_register_file.v" ^
  "%PROJECT_DIR%\rtl\dma\dma6_scheduler.v" ^
  "%PROJECT_DIR%\rtl\dma\dma6_core.v" ^
  "%SCRIPT_DIR%tb_dma6_mixed_burst_16.sv"
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xelab.bat" xil_defaultlib.tb_dma6_mixed_burst_16 ^
  -s tb_dma6_mixed_burst_16_behav -debug typical --relax
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xsim.bat" tb_dma6_mixed_burst_16_behav -runall ^
  -log dma_mixed16.log
if errorlevel 1 exit /b 1

rem XSim 2019.2 can return 0 after $fatal, so require the PASS marker.
findstr /C:"TEST PASS: DMA mixed Burst and UART beat conversion are correct" ^
  dma_mixed16.log >nul
if errorlevel 1 exit /b 1

exit /b 0
