@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
if not defined VIVADO_BIN for %%I in (xvlog.bat) do set "VIVADO_BIN=%%~dp$PATH:I"
if not defined VIVADO_BIN (
  echo ERROR: Set VIVADO_BIN to the Vivado bin directory or add Vivado to PATH.
  exit /b 2
)
set "PROJECT_DIR=%SCRIPT_DIR%..\.."
set "BUILD_DIR=%SCRIPT_DIR%xsim_work_apb_uart_fifo"
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
cd /d "%BUILD_DIR%"

call "%VIVADO_BIN%\xvlog.bat" --sv --work xil_defaultlib ^
  "%PROJECT_DIR%\rtl\uart\uart_tx_byte.v" ^
  "%PROJECT_DIR%\rtl\uart\uart_rx_byte.v" ^
  "%PROJECT_DIR%\rtl\uart\apb_uart.v" ^
  "%PROJECT_DIR%\rtl\uart\apb_uart_shell.v" ^
  "%SCRIPT_DIR%tb_apb_uart_fifo.sv"
if errorlevel 1 exit /b 1
call "%VIVADO_BIN%\xelab.bat" xil_defaultlib.tb_apb_uart_fifo ^
  -s tb_apb_uart_fifo_behav --relax
if errorlevel 1 exit /b 1
call "%VIVADO_BIN%\xsim.bat" tb_apb_uart_fifo_behav -runall ^
  -log apb_uart_fifo.log
if errorlevel 1 exit /b 1
findstr /C:"TEST PASS: APB UART dual FIFO" apb_uart_fifo.log >nul
if errorlevel 1 exit /b 1
exit /b 0
