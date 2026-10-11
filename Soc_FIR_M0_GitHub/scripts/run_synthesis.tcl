set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set project_xpr [file join $repo_dir build vivado Soc_FIR_M0.xpr]
set report_dir  [file join $repo_dir reports generated synthesis]

if {![file exists $project_xpr]} {
    error "Vivado project not found: $project_xpr\nRun scripts/create_vivado_project.tcl first."
}

file mkdir $report_dir
open_project $project_xpr
reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1

set run_status [get_property STATUS [get_runs synth_1]]
puts "SYNTHESIS_STATUS=$run_status"
if {![string match "*Complete*" $run_status]} {
    close_project
    error "Synthesis did not complete"
}

open_run synth_1
report_utilization -file [file join $report_dir utilization_synth.rpt]
report_timing_summary -file [file join $report_dir timing_synth.rpt]
report_drc -file [file join $report_dir drc_synth.rpt]
close_project
puts "Synthesis reports: $report_dir"

