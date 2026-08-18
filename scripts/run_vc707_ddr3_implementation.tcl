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
set uart_axil_source [file join $root_dir "src/UART/uart_axil_axis.sv"]
if {[llength [get_files -quiet $uart_axil_source]] == 0} {
    add_files -fileset sources_1 -norecurse $uart_axil_source
    set_property file_type SystemVerilog [get_files $uart_axil_source]
}

# Selectable firmware/QoR policy lets the same timing-closed physical target
# build either the standalone DDR acceptance image or the complete UART image
# DMA SoC. All paths remain reproducible from tracked source and prebuilt HEX.
set firmware_rel "firmware/prebuilt/vc707_ddr3/soc_ddr3_test.hex"
set report_subdir "vc707_ddr3"
set bit_name "DMA_IOMMU_PicoRV32_VC707_DDR3.bit"
set bram_addr_width 18
set uart_default_div 1300
set require_zero_dsp 0
if {[info exists ::env(VC707_FIRMWARE_HEX)] && $::env(VC707_FIRMWARE_HEX) ne ""} {
    set firmware_rel $::env(VC707_FIRMWARE_HEX)
}
if {[info exists ::env(VC707_REPORT_SUBDIR)] && $::env(VC707_REPORT_SUBDIR) ne ""} {
    set report_subdir $::env(VC707_REPORT_SUBDIR)
}
if {[info exists ::env(VC707_BIT_NAME)] && $::env(VC707_BIT_NAME) ne ""} {
    set bit_name $::env(VC707_BIT_NAME)
}
if {[info exists ::env(VC707_BRAM_ADDR_WIDTH)] && $::env(VC707_BRAM_ADDR_WIDTH) ne ""} {
    set bram_addr_width $::env(VC707_BRAM_ADDR_WIDTH)
}
if {[info exists ::env(VC707_UART_DIVIDER)] && $::env(VC707_UART_DIVIDER) ne ""} {
    set uart_default_div $::env(VC707_UART_DIVIDER)
}
if {[info exists ::env(VC707_REQUIRE_ZERO_DSP)] && $::env(VC707_REQUIRE_ZERO_DSP) eq "1"} {
    set require_zero_dsp 1
}
# Keep an explicitly supplied junction path intact. Vivado 2025.1 cannot pass
# a MEM_INIT_FILE path containing parentheses through the synthesis launcher,
# while file normalize would resolve D:/_codex_dma_mmu back to that path.
set firmware_file [string map {\\ /} [file join $root_dir $firmware_rel]]
if {![file exists $firmware_file]} {
    error "Firmware image not found: $firmware_file"
}
if {[llength [get_files -quiet $firmware_file]] == 0} {
    add_files -norecurse $firmware_file
    set_property file_type {Memory Initialization Files} [get_files $firmware_file]
}
set_property generic "MEM_INIT_FILE=$firmware_file BRAM_ADDR_WIDTH=$bram_addr_width UART_DEFAULT_DIV=$uart_default_div" \
    [get_filesets sources_1]
update_compile_order -fileset sources_1
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
set report_dir [file join $root_dir "reports/$report_subdir"]
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
# The board top fixes the SoC clock at 150 MHz (6.667 ns rounded in reports).
# This is a slack-equivalent estimate, not a replacement for a new routed run
# when changing the MMCM frequency.
set soc_period_ns 6.667
set estimated_fmax [expr {1000.0 / ($soc_period_ns - $setup_wns)}]
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
set drc_critical [llength [get_drc_violations -quiet -filter {SEVERITY == {Critical Warning}}]]
set fd [open [file join $report_dir "vc707_ddr3_build_summary.txt"] w]
puts $fd "VC707 complete PicoRV32 + DMA/IOMMU + AXI RAM + MIG DDR3 implementation"
puts $fd "Part              : xc7vx485tffg1761-2"
puts $fd "Synthesis status  : $synth_status"
puts $fd "Implementation    : $impl_status"
puts $fd "Post-route WNS    : $setup_wns ns"
puts $fd "Post-route WHS    : $hold_wns ns"
puts $fd [format "SoC target clock  : 150.000 MHz"]
puts $fd [format "Estimated Fmax    : %.3f MHz (slack-equivalent)" $estimated_fmax]
puts $fd "DRC errors        : $drc_errors"
puts $fd "DRC critical warn : $drc_critical"
puts $fd "DSP total SoC     : $all_dsp (systolic accelerator: [expr {$all_dsp - $memory_dsp}])"
puts $fd "DSP MIG/DDR path  : $memory_dsp"
puts $fd "Firmware          : $firmware_rel"
puts $fd "Board validation  : run firmware and capture UART after programming"
close $fd

set fmax_fd [open [file join $report_dir "vc707_unified_fmax.txt"] w]
puts $fmax_fd "VC707 UNIFIED SOC POST-ROUTE FMAX ESTIMATE"
puts $fmax_fd "Target clock      : 150.000 MHz"
puts $fmax_fd [format "Constraint period : %.3f ns" $soc_period_ns]
puts $fmax_fd [format "Post-route WNS    : %.3f ns" $setup_wns]
puts $fmax_fd [format "Critical period   : %.3f ns" [expr {$soc_period_ns - $setup_wns}]]
puts $fmax_fd [format "Estimated Fmax    : %.3f MHz" $estimated_fmax]
puts $fmax_fd "Formula           : 1000 / (constraint period - WNS)"
puts $fmax_fd "Boundary          : reroute is required to certify a changed clock target"
close $fmax_fd

set generated_bit [file join [get_property DIRECTORY [get_runs impl_1]] \
    "$top_name.bit"]
if {![file exists $generated_bit]} {
    error "Vivado reports success but bitstream was not found: $generated_bit"
}
set final_bit [file join $bit_dir $bit_name]
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
if {$require_zero_dsp && $all_dsp != 0} {
    error "VC707 unified SoC violates zero-DSP requirement: DSP total=$all_dsp"
}
puts "VC707 DDR3 BITSTREAM PASSED: WNS=$setup_wns ns; DSP total=$all_dsp; MIG/DDR DSP=$memory_dsp"
puts "Bitstream: $final_bit"
