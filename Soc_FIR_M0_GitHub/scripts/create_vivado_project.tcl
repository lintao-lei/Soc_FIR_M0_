# Create a clean Vivado 2019.2 project from the repository source tree.
# Generated files are written below build/ and are intentionally not tracked.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set build_dir  [file join $repo_dir build vivado]
set project_name Soc_FIR_M0

if {[info exists ::env(FPGA_PART)] && $::env(FPGA_PART) ne ""} {
    set fpga_part $::env(FPGA_PART)
} else {
    set fpga_part xc7a100tcsg324-1
}

if {[info exists ::env(ARM_CORTEX_M0_RTL_DIR)] &&
    $::env(ARM_CORTEX_M0_RTL_DIR) ne ""} {
    set arm_vendor_dir [file normalize $::env(ARM_CORTEX_M0_RTL_DIR)]
} else {
    set arm_vendor_dir [file join $repo_dir rtl cortex_m0 vendor]
}

set arm_integration [file join $arm_vendor_dir CORTEXM0INTEGRATION.v]
set arm_logic       [file join $arm_vendor_dir cortexm0ds_logic.v]
foreach arm_file [list $arm_integration $arm_logic] {
    if {![file exists $arm_file]} {
        error "Missing licensed Cortex-M0 RTL: $arm_file\nSet ARM_CORTEX_M0_RTL_DIR or populate rtl/cortex_m0/vendor/."
    }
}

set design_files [list \
    $arm_logic \
    $arm_integration \
    [file join $repo_dir rtl cortex_m0 cortex_m0_subsystem.v] \
    [file join $repo_dir rtl ahb_to_axi ahb_to_axi_bridge.v] \
    [file join $repo_dir rtl sram simple_sram_core.v] \
    [file join $repo_dir rtl sram axi_burst_sram.v] \
    [file join $repo_dir rtl interconnect axi_interconnect_shell_reference.v] \
    [file join $repo_dir rtl fir fir_81tap_core.v] \
    [file join $repo_dir rtl fir fir_81tap_axi.v] \
    [file join $repo_dir rtl fir axi_fir_data.v] \
    [file join $repo_dir rtl fir fir_subsystem.v] \
    [file join $repo_dir rtl uart uart_tx_byte.v] \
    [file join $repo_dir rtl uart uart_rx_byte.v] \
    [file join $repo_dir rtl uart apb_uart.v] \
    [file join $repo_dir rtl uart apb_uart_shell.v] \
    [file join $repo_dir rtl axi_to_apb axi_to_apb_bridge.v] \
    [file join $repo_dir rtl uart axi_apb_uart_subsystem.v] \
    [file join $repo_dir rtl dma axi_dma_reg_slave.v] \
    [file join $repo_dir rtl dma dma6_register_file.v] \
    [file join $repo_dir rtl dma dma6_scheduler.v] \
    [file join $repo_dir rtl dma dma_carry.v] \
    [file join $repo_dir rtl dma dma6_core.v] \
    [file join $repo_dir rtl interconnect read_arbiter.v] \
    [file join $repo_dir rtl interconnect write_arbiter.v] \
    [file join $repo_dir rtl interconnect arbiter.v] \
    [file join $repo_dir rtl interconnect axi_interconnect_shell.v] \
    [file join $repo_dir rtl soc soc_clock_reset.v] \
    [file join $repo_dir rtl soc soc_fabric_shell.v] \
    [file join $repo_dir rtl soc soc_top.v] \
]

set header_file [file join $repo_dir rtl include soc_addr_map.vh]
foreach source_file [concat $design_files [list $header_file]] {
    if {![file exists $source_file]} {
        error "Missing design source: $source_file"
    }
}

file mkdir $build_dir
create_project -force $project_name $build_dir -part $fpga_part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -fileset sources_1 -norecurse $design_files
add_files -fileset sources_1 -norecurse $header_file
set_property file_type {Verilog Header} [get_files $header_file]
set_property include_dirs [list [file join $repo_dir rtl include]] \
    [get_filesets sources_1]
set_property top soc_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]

set board_xdc [file join $repo_dir constraints board.xdc]
if {[file exists $board_xdc]} {
    add_files -fileset constrs_1 -norecurse $board_xdc
    puts "Using board constraints: $board_xdc"
} else {
    puts "WARNING: constraints/board.xdc is absent. Project is for simulation/synthesis inspection only; do not generate a board bitstream yet."
}

update_compile_order -fileset sources_1
puts "Created project: [file join $build_dir ${project_name}.xpr]"
puts "Top: soc_top"
puts "Part: $fpga_part"
close_project

