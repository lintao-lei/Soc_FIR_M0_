@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
if not defined VIVADO_BIN for %%I in (xvlog.bat) do set "VIVADO_BIN=%%~dp$PATH:I"
if not defined VIVADO_BIN (
  echo ERROR: Set VIVADO_BIN to the Vivado bin directory or add Vivado to PATH.
  exit /b 2
)
set "PROJECT_DIR=%SCRIPT_DIR%..\.."
set "BUILD_DIR=%SCRIPT_DIR%xsim_work_dma_config_integration"
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
cd /d "%BUILD_DIR%"

call "%VIVADO_BIN%\xvlog.bat" --sv --work xil_defaultlib -i "%PROJECT_DIR%\rtl\include" ^
  "%PROJECT_DIR%\rtl\sram\simple_sram_core.v" ^
  "%PROJECT_DIR%\rtl\sram\axi_burst_sram.v" ^
  "%PROJECT_DIR%\rtl\interconnect\axi_interconnect_shell_reference.v" ^
  "%PROJECT_DIR%\rtl\fir\fir_81tap_core.v" ^
  "%PROJECT_DIR%\rtl\fir\fir_81tap_axi.v" ^
  "%PROJECT_DIR%\rtl\fir\axi_fir_data.v" ^
  "%PROJECT_DIR%\rtl\fir\fir_subsystem.v" ^
  "%PROJECT_DIR%\rtl\uart\uart_tx_byte.v" ^
  "%PROJECT_DIR%\rtl\uart\uart_rx_byte.v" ^
  "%PROJECT_DIR%\rtl\uart\apb_uart.v" ^
  "%PROJECT_DIR%\rtl\uart\apb_uart_shell.v" ^
  "%PROJECT_DIR%\rtl\axi_to_apb\axi_to_apb_bridge.v" ^
  "%PROJECT_DIR%\rtl\uart\axi_apb_uart_subsystem.v" ^
  "%PROJECT_DIR%\rtl\interconnect\axi_interconnect_shell.v" ^
  "%PROJECT_DIR%\rtl\dma\axi_dma_reg_slave.v" ^
  "%PROJECT_DIR%\rtl\interconnect\read_arbiter.v" ^
  "%PROJECT_DIR%\rtl\interconnect\write_arbiter.v" ^
  "%PROJECT_DIR%\rtl\interconnect\arbiter.v" ^
  "%PROJECT_DIR%\rtl\dma\dma_test.v" ^
  "%PROJECT_DIR%\rtl\dma\dma_carry.v" ^
  "%PROJECT_DIR%\rtl\dma\dma_register_config.v" ^
  "%PROJECT_DIR%\rtl\dma\dma_configured_core.v" ^
  "%SCRIPT_DIR%tb_dma_config_integration.sv"
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xelab.bat" xil_defaultlib.tb_dma_config_integration ^
  -s tb_dma_config_integration_behav --relax
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xsim.bat" tb_dma_config_integration_behav -runall ^
  -log dma_config_integration.log
if errorlevel 1 exit /b 1

rem XSim 2019.2 can return success after Verilog $fatal: require the PASS marker.
findstr /C:"TEST PASS: DMA register-config integration" dma_config_integration.log >nul
if errorlevel 1 exit /b 1
exit /b 0
