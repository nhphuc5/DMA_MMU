# Build the complete VC707 MIG/DDR3 system through bitstream and archive
# reproducible timing, utilization, DRC, IP and clock reports.
set script_dir [file dirname [file normalize [info script]]]
if {[info exists ::env(VC707_DDR3_PROJECT_ROOT)]
        && $::env(VC707_DDR3_PROJECT_ROOT) ne ""} {
    set root_dir $::env(VC707_DDR3_PROJECT_ROOT)
} else {
    set root_dir [file normalize [file join $script_dir ".."]]
}
set project_dir [file join $root_dir "build/vivado/vc707_ddr3"]
set xpr_file [file join $project_dir "DMA_IOMMU_PicoRV32_VC707_DDR3.xpr"]

if {![file exists $xpr_file]} {
    # The common project creator uses VC707_PROJECT_ROOT.  Propagate the
    # DDR3-specific root so junction paths that avoid unsupported characters
    # remain intact during first-time project creation.
    set ::env(VC707_PROJECT_ROOT) $root_dir
    source [file join $root_dir "scripts/create_vc707_ddr3_project.tcl"]
} elseif {[current_project -quiet] eq ""} {
    open_project $xpr_file
}

set top_name dma_mmu_picorv32_vc707_ddr3_top
set_property top $top_name [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
    [get_runs impl_1]

set reuse_synth [expr {[info exists ::env(VC707_DDR3_REUSE_SYNTH)]
                       && $::env(VC707_DDR3_REUSE_SYNTH) eq "1"}]
if {!$reuse_synth} {
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
}
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    error "VC707 DDR3 synthesis failed ($synth_status); inspect synth_1/runme.log"
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*Complete*" $impl_status]} {
    error "VC707 DDR3 implementation failed ($impl_status); inspect impl_1/runme.log"
}

open_run impl_1
set report_dir [file join $root_dir "reports/vc707_ddr3"]
set bit_dir [file join $root_dir "bitstream"]
file mkdir $report_dir
file mkdir $bit_dir

report_utilization -hierarchical -file \
    [file join $report_dir "vc707_ddr3_utilization_hierarchical.rpt"]
report_utilization -file [file join $report_dir "vc707_ddr3_utilization.rpt"]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $report_dir "vc707_ddr3_timing.rpt"]
report_bus_skew -file [file join $report_dir "vc707_ddr3_bus_skew.rpt"]
report_drc -file [file join $report_dir "vc707_ddr3_drc.rpt"]
report_clocks -file [file join $report_dir "vc707_ddr3_clocks.rpt"]
report_ip_status -file [file join $report_dir "vc707_ddr3_ip_status.rpt"]

# Preserve the exact tool transcripts, including device/license checkout and
# every synthesis/implementation warning, beside the summarized reports.
foreach run_name {synth_1 impl_1} report_name \
        {vc707_ddr3_synthesis.log vc707_ddr3_implementation.log} {
    set run_log [file join [get_property DIRECTORY [get_runs $run_name]] "runme.log"]
    if {[file exists $run_log]} {
        file copy -force $run_log [file join $report_dir $report_name]
    }
}

set dsp_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ DSP48*}]
set all_dsp [llength $dsp_cells]
set memory_dsp 0
foreach dsp_cell $dsp_cells {
    set dsp_name [get_property NAME $dsp_cell]
    if {[string match "mig_inst/*" $dsp_name]
            || [string match "ddr_clock_converter_inst/*" $dsp_name]
            || [string match "ddr_axi_converter_inst/*" $dsp_name]} {
        incr memory_dsp
    }
}
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set setup_wns [get_property SLACK $setup_paths]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
set hold_wns [get_property SLACK $hold_paths]
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
set drc_critical [llength [get_drc_violations -quiet -filter {SEVERITY == {Critical Warning}}]]
set fd [open [file join $report_dir "vc707_ddr3_build_summary.txt"] w]
puts $fd "VC707 complete PicoRV32 + DMA/IOMMU + AXI RAM + MIG DDR3 implementation"
puts $fd "Part              : xc7vx485tffg1761-2"
puts $fd "Synthesis status  : $synth_status"
puts $fd "Implementation    : $impl_status"
puts $fd "Post-route WNS    : $setup_wns ns"
puts $fd "Post-route WHS    : $hold_wns ns"
puts $fd "DRC errors        : $drc_errors"
puts $fd "DRC critical warn : $drc_critical"
puts $fd "DSP total SoC     : $all_dsp (systolic accelerator: [expr {$all_dsp - $memory_dsp}])"
puts $fd "DSP MIG/DDR path  : $memory_dsp"
puts $fd "Firmware          : firmware/prebuilt/vc707_ddr3/soc_ddr3_test.hex"
puts $fd "Board validation  : run firmware and capture UART after programming"
close $fd

set generated_bit [file join [get_property DIRECTORY [get_runs impl_1]] \
    "$top_name.bit"]
if {![file exists $generated_bit]} {
    error "Vivado reports success but bitstream was not found: $generated_bit"
}
set final_bit [file join $bit_dir "DMA_IOMMU_PicoRV32_VC707_DDR3.bit"]
file copy -force $generated_bit $final_bit

if {$setup_wns < 0.0} {
    error "VC707 DDR3 routed but failed timing: WNS=$setup_wns ns"
}
if {$hold_wns < 0.0} {
    error "VC707 DDR3 routed but failed hold timing: WHS=$hold_wns ns"
}
if {$drc_errors != 0} {
    error "VC707 DDR3 routed but has $drc_errors DRC errors"
}
puts "VC707 DDR3 BITSTREAM PASSED: WNS=$setup_wns ns; DSP total=$all_dsp; MIG/DDR DSP=$memory_dsp"
puts "Bitstream: $final_bit"
