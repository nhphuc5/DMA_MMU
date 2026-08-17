# Build the hardware image for the complete 256-KiB image pipeline on VC707.
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
set build_subdir [expr {$argc > 0 ? [lindex $argv 0] : "vc707_systolic_image_dma"}]
set xpr [file join $root_dir "build/vivado/$build_subdir/DMA_IOMMU_PicoRV32_VC707_Systolic_Image_DMA.xpr"]

if {![file exists $xpr]} {
    error "Project not found: $xpr"
}

open_project $xpr
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "Synthesis failed; inspect [get_property DIRECTORY [get_runs synth_1]]/runme.log"
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Implementation failed; inspect [get_property DIRECTORY [get_runs impl_1]]/runme.log"
}

open_run impl_1
set report_dir [file join $root_dir "reports/vc707_systolic_image_dma"]
set bit_dir [file join $root_dir "bitstream"]
file mkdir $report_dir
file mkdir $bit_dir
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $report_dir "timing.rpt"]
report_utilization -hierarchical -file [file join $report_dir "utilization.rpt"]
report_drc -file [file join $report_dir "drc.rpt"]

set generated_bit [file join [get_property DIRECTORY [get_runs impl_1]] \
    "dma_mmu_picorv32_vc707_top.bit"]
set final_bit [file join $bit_dir \
    "DMA_IOMMU_PicoRV32_VC707_Systolic_Image_DMA.bit"]
if {![file exists $generated_bit]} {
    error "Implementation completed but bitstream is missing: $generated_bit"
}
file copy -force $generated_bit $final_bit
puts "IMAGE DMA VC707 IMPLEMENTATION PASSED"
puts "BITSTREAM: $final_bit"
close_project
exit 0
