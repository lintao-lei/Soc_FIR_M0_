set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set project_xpr [file join $repo_dir build vivado Soc_FIR_M0.xpr]
set board_xdc   [file join $repo_dir constraints board.xdc]
set report_dir  [file join $repo_dir reports generated implementation]

if {![file exists $board_xdc]} {
    error "Refusing implementation: constraints/board.xdc is absent. Copy board_template.xdc and fill the real board pins/clock first."
}
if {![file exists $project_xpr]} {
    error "Vivado project not found: $project_xpr\nCreate it after board.xdc is ready."
}

file mkdir $report_dir
open_project $project_xpr
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1

set run_status [get_property STATUS [get_runs impl_1]]
puts "IMPLEMENTATION_STATUS=$run_status"
if {![string match "*Complete*" $run_status]} {
    close_project
    error "Implementation or bitstream generation did not complete"
}

open_run impl_1
report_utilization -file [file join $report_dir utilization_impl.rpt]
report_timing_summary -file [file join $report_dir timing_impl.rpt]
report_drc -file [file join $report_dir drc_impl.rpt]
close_project
puts "Implementation reports: $report_dir"

