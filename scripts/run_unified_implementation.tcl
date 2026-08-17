# Synthesize and implement the unified PicoRV32 + DMA/IOMMU + UART project.
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
if {[info exists ::env(DMA_PROJECT_OUT_DIR)]
        && $::env(DMA_PROJECT_OUT_DIR) ne ""} {
    set project_dir [file normalize $::env(DMA_PROJECT_OUT_DIR)]
} else {
    set project_dir [file join $root_dir "build/vivado/unified"]
}
set xpr_file [file join $project_dir "DMA_IOMMU_PicoRV32_Unified.xpr"]

if {![file exists $xpr_file]} {
    source [file join $script_dir "create_unified_project.tcl"]
} elseif {[current_project -quiet] eq "" || \
          [file normalize [get_property DIRECTORY [current_project]]] ne \
          [file normalize [file dirname $xpr_file]]} {
    catch {close_project}
    open_project $xpr_file
}

source [file join $script_dir "ensure_descriptor_queue_sources.tcl"]
ensure_descriptor_queue_sources $root_dir

file mkdir [file join $root_dir "reports"]
set_property top dma_mmu_picorv32_soc [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
    [get_runs impl_1]

set synth_status  [get_property STATUS [get_runs synth_1]]
set synth_refresh [get_property NEEDS_REFRESH [get_runs synth_1]]
if {$synth_refresh || ![string match "*Complete*" $synth_status]} {
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
}
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "Unified synthesis failed. Open synth_1/runme.log."
}

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Unified implementation failed. Open impl_1/runme.log."
}

open_run impl_1
set util_report [file join $root_dir "reports/unified_utilization.rpt"]
set time_report [file join $root_dir "reports/unified_timing.rpt"]
set fmax_report [file join $root_dir "reports/unified_fmax.txt"]
report_utilization -file $util_report
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file $time_report

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set setup_wns  [get_property SLACK $setup_path]
set sys_period [get_property PERIOD [get_clocks sys_clk]]
set estimated_fmax [expr {1000.0 / ($sys_period - $setup_wns)}]
set critical_period [expr {$sys_period - $setup_wns}]
set fd [open $fmax_report w]
puts $fd "Unified PicoRV32 + DMA/IOMMU implementation"
puts $fd [format "Constraint period : %.3f ns" $sys_period]
puts $fd [format "Post-route WNS    : %.3f ns" $setup_wns]
puts $fd "Formula           : Tcritical(ns) = Tconstraint(ns) - WNS(ns)"
puts $fd [format "Substitution      : %.3f - %.3f = %.3f ns" \
    $sys_period $setup_wns $critical_period]
puts $fd "Formula           : Fmax(MHz) = 1000 / Tcritical(ns)"
puts $fd [format "Substitution      : 1000 / %.3f = %.3f MHz" \
    $critical_period $estimated_fmax]
puts $fd [format "Estimated Fmax    : %.3f MHz" $estimated_fmax]
close $fd

if {$setup_wns < 0.0} {
    error "Unified routing completed but timing failed: WNS=$setup_wns ns."
}
puts [format "Unified implementation PASSED: WNS %.3f ns, estimated Fmax %.3f MHz" \
             $setup_wns $estimated_fmax]

# Also generate timing/Fmax reports scoped separately to the DMA and IOMMU.
source [file join $script_dir "report_dma_iommu_fmax.tcl"]
