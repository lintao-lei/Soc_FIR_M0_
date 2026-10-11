# Board constraint template - intentionally inactive.
#
# Do not uncomment or fill pin locations until the exact development-board
# model and oscillator frequency are confirmed. The current project device is
# xc7a100tcsg324-1, but that does not uniquely identify the board.
#
# Example structure only:
# set_property PACKAGE_PIN <CLOCK_PIN> [get_ports clk_board]
# set_property IOSTANDARD LVCMOS33 [get_ports clk_board]
# create_clock -name clk_board -period <PERIOD_NS> [get_ports clk_board]
#
# set_property PACKAGE_PIN <RESET_PIN> [get_ports reset_n]
# set_property IOSTANDARD LVCMOS33 [get_ports reset_n]
#
# set_property PACKAGE_PIN <UART_RX_PIN> [get_ports uart_rx]
# set_property PACKAGE_PIN <UART_TX_PIN> [get_ports uart_tx]
# set_property IOSTANDARD LVCMOS33 [get_ports {uart_rx uart_tx}]
#
# set_property PACKAGE_PIN <LED_RUN_PIN> [get_ports led_run]
# set_property PACKAGE_PIN <LED_ERROR_PIN> [get_ports led_error]
# set_property IOSTANDARD LVCMOS33 [get_ports {led_run led_error}]
