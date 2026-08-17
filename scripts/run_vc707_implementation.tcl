# Synthesize, implement, generate the VC707 bitstream, and write reports.
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
set project_dir [file join $root_dir "build/vivado/vc707"]
set xpr_file [file join $project_dir "DMA_IOMMU_PicoRV32_VC707.xpr"]

if {![file exists $xpr_file]} {
    source [file join $script_dir "create_vc707_project.tcl"]
} elseif {[current_project -quiet] eq ""} {
    open_project $xpr_file
}

set_property top dma_mmu_picorv32_vc707_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
    [get_runs impl_1]

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "VC707 synthesis failed; inspect build/vivado/vc707/*.runs/synth_1/runme.log"
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "VC707 implementation/bitstream failed; inspect impl_1/runme.log"
}

open_run impl_1
set report_dir [file join $root_dir "reports/vc707"]
set bit_dir [file join $root_dir "bitstream"]
file mkdir $report_dir
file mkdir $bit_dir

report_utilization -hierarchical -file \
    [file join $report_dir "vc707_utilization.rpt"]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $report_dir "vc707_timing.rpt"]
report_drc -file [file join $report_dir "vc707_drc.rpt"]

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set setup_wns [get_property SLACK $setup_path]
set soc_clock [get_clocks -quiet -of_objects \
    [get_pins -quiet soc_clock_bufg_inst/O]]
if {[llength $soc_clock] == 0} {
    set soc_clock [get_clocks -quiet *clkout0*]
}
set soc_period [get_property PERIOD [lindex $soc_clock 0]]
set critical_period [expr {$soc_period - $setup_wns}]
set estimated_fmax [expr {1000.0 / $critical_period}]
set fd [open [file join $report_dir "vc707_fmax.txt"] w]
puts $fd "VC707 PicoRV32 + DMA/IOMMU implementation"
puts $fd "Part              : xc7vx485tffg1761-2"
puts $fd [format "SoC constraint    : %.3f ns (%.3f MHz)" \
    $soc_period [expr {1000.0/$soc_period}]]
puts $fd [format "Post-route WNS    : %.3f ns" $setup_wns]
puts $fd "Formula           : Fmax(MHz) = 1000 / (Tconstraint - WNS)"
puts $fd [format "Estimated Fmax    : %.3f MHz" $estimated_fmax]
close $fd

set generated_bit [file join \
    [get_property DIRECTORY [get_runs impl_1]] \
    "dma_mmu_picorv32_vc707_top.bit"]
if {![file exists $generated_bit]} {
    error "Vivado reports success but bitstream was not found: $generated_bit"
}
set final_bit [file join $bit_dir "DMA_IOMMU_PicoRV32_VC707.bit"]
file copy -force $generated_bit $final_bit

if {$setup_wns < 0.0} {
    error "VC707 routed but failed timing: WNS=$setup_wns ns"
}
puts [format "VC707 PASSED: WNS %.3f ns; estimated Fmax %.3f MHz" \
    $setup_wns $estimated_fmax]
puts "Bitstream: $final_bit"

