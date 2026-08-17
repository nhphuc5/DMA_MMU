# Out-of-context synthesis and timing/resource report for the custom DDR3 IP.
set script_dir [file dirname [file normalize [info script]]]
if {[info exists ::env(DDR3_PROJECT_ROOT)]
        && $::env(DDR3_PROJECT_ROOT) ne ""} {
    set root_dir $::env(DDR3_PROJECT_ROOT)
} else {
    set root_dir [file normalize [file join $script_dir ".."]]
}
if {[info exists ::env(DDR3_CONTROLLER_OOC_DIR)]
        && $::env(DDR3_CONTROLLER_OOC_DIR) ne ""} {
    set out_dir [file normalize $::env(DDR3_CONTROLLER_OOC_DIR)]
} else {
    set out_dir [file join $root_dir "build/vivado/ddr3_controller_ooc"]
}
set report_dir [file join $root_dir "reports/ddr3_controller"]
if {[info exists ::env(DDR3_SYNTH_PART)]
        && $::env(DDR3_SYNTH_PART) ne ""} {
    set part_name $::env(DDR3_SYNTH_PART)
} else {
    set part_name "xc7vx485tffg1761-2"
}
file mkdir $out_dir
file mkdir $report_dir

catch {close_project}
create_project -force DDR3_Controller_OOC $out_dir \
    -part $part_name
add_files -fileset sources_1 -norecurse [list \
    [file join $root_dir "src/Memory/ddr3_controller_core.sv"] \
    [file join $root_dir "src/Memory/axi_ddr3_controller.sv"] \
]
foreach f [get_files -of_objects [get_filesets sources_1]] {
    set_property FILE_TYPE SystemVerilog $f
}
set_property top axi_ddr3_controller [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
update_compile_order -fileset sources_1

synth_design -top axi_ddr3_controller -part $part_name \
    -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name axi_clk -period 3.000 [get_ports aclk]
# OOC timing needs an assumed global-buffer origin; without this property
# Vivado reports pessimistic/uncontrolled clock insertion delay and skew.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports aclk]
set_false_path -from [get_ports aresetn]
opt_design

report_utilization -hierarchical -file \
    [file join $report_dir "utilization_synth.rpt"]
report_timing_summary -delay_type max -max_paths 20 \
    -report_unconstrained -check_timing_verbose \
    -file [file join $report_dir "timing_synth.rpt"]

set dsp_count 0
set dsp_cells [get_cells -hierarchical -quiet -filter {REF_NAME =~ DSP*}]
if {[llength $dsp_cells] != 0} {
    set dsp_count [llength $dsp_cells]
}
set path [get_timing_paths -delay_type max -max_paths 1]
set slack [get_property SLACK $path]
set period 3.000
set critical_period [expr {$period - $slack}]
set fmax [expr {1000.0 / $critical_period}]
set fd [open [file join $report_dir "summary.txt"] w]
puts $fd "CUSTOM AXI DDR3 CONTROLLER OOC SYNTHESIS"
puts $fd "Part: $part_name"
puts $fd "Constraint: $period ns"
puts $fd [format "Worst slack: %.3f ns" $slack]
puts $fd [format "Estimated post-synthesis Fmax: %.3f MHz" $fmax]
puts $fd "DSP cells: $dsp_count"
close $fd
if {$dsp_count != 0} {
    error "Zero-DSP requirement failed: found $dsp_count DSP cells"
}
puts [format "DDR3 controller synthesis: DSP=%d, estimated Fmax=%.3f MHz" \
    $dsp_count $fmax]
close_project
