@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
if not defined VIVADO_BIN for %%I in (xvlog.bat) do set "VIVADO_BIN=%%~dp$PATH:I"
if not defined VIVADO_BIN (
  echo ERROR: Set VIVADO_BIN to the Vivado bin directory or add Vivado to PATH.
  exit /b 2
)
set "PROJECT_DIR=%SCRIPT_DIR%..\.."
if defined ARM_CORTEX_M0_RTL_DIR (
  set "CORTEX_M0_VENDOR_DIR=%ARM_CORTEX_M0_RTL_DIR%"
) else (
  set "CORTEX_M0_VENDOR_DIR=%PROJECT_DIR%\rtl\cortex_m0\vendor"
)
if not exist "%CORTEX_M0_VENDOR_DIR%\CORTEXM0INTEGRATION.v" (
  echo ERROR: Missing licensed Cortex-M0 RTL. Set ARM_CORTEX_M0_RTL_DIR.
  exit /b 2
)
if not exist "%CORTEX_M0_VENDOR_DIR%\cortexm0ds_logic.v" (
  echo ERROR: Missing licensed Cortex-M0 RTL. Set ARM_CORTEX_M0_RTL_DIR.
  exit /b 2
)
set "BUILD_DIR=%SCRIPT_DIR%xsim_work_cpu_uart_echo"

if /I not "%SKIP_FIRMWARE_BUILD%"=="1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_cpu_uart_echo_firmware.ps1"
  if errorlevel 1 exit /b 1
)

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
cd /d "%BUILD_DIR%"

call "%VIVADO_BIN%\xvlog.bat" --work xil_defaultlib -i "%PROJECT_DIR%\rtl\include" ^
  "%CORTEX_M0_VENDOR_DIR%\cortexm0ds_logic.v" ^
  "%CORTEX_M0_VENDOR_DIR%\CORTEXM0INTEGRATION.v" ^
  "%PROJECT_DIR%\rtl\cortex_m0\cortex_m0_subsystem.v" ^
  "%PROJECT_DIR%\rtl\ahb_to_axi\ahb_to_axi_bridge.v" ^
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
  "%PROJECT_DIR%\rtl\dma\axi_dma_reg_slave.v" ^
  "%PROJECT_DIR%\rtl\dma\dma6_register_file.v" ^
  "%PROJECT_DIR%\rtl\dma\dma6_scheduler.v" ^
  "%PROJECT_DIR%\rtl\dma\dma_carry.v" ^
  "%PROJECT_DIR%\rtl\dma\dma6_core.v" ^
  "%PROJECT_DIR%\rtl\interconnect\read_arbiter.v" ^
  "%PROJECT_DIR%\rtl\interconnect\write_arbiter.v" ^
  "%PROJECT_DIR%\rtl\interconnect\arbiter.v" ^
  "%PROJECT_DIR%\rtl\interconnect\axi_interconnect_shell.v" ^
  "%PROJECT_DIR%\rtl\soc\soc_clock_reset.v" ^
  "%PROJECT_DIR%\rtl\soc\soc_fabric_shell.v" ^
  "%PROJECT_DIR%\rtl\soc\soc_top.v"
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xvlog.bat" --sv --work xil_defaultlib ^
  "%SCRIPT_DIR%tb_soc_top_cpu_uart_echo.sv"
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xelab.bat" xil_defaultlib.tb_soc_top_cpu_uart_echo ^
  -s tb_soc_top_cpu_uart_echo_behav -debug typical --relax
if errorlevel 1 exit /b 1

call "%VIVADO_BIN%\xsim.bat" tb_soc_top_cpu_uart_echo_behav -runall ^
  -log soc_top_cpu_uart_echo.log
if errorlevel 1 exit /b 1

findstr /C:"TEST PASS: Cortex-M0 polling UART full echo regression" soc_top_cpu_uart_echo.log >nul
if errorlevel 1 exit /b 1
exit /b 0
