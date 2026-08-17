# Run the complete CPU + DMA/IOMMU + AXI + systolic + image regression.
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
if {$argc > 0} {
    set build_subdir [lindex $argv 0]
} else {
    set build_subdir "vc707_systolic_image_dma"
}
set xpr [file join $root_dir "build/vivado/$build_subdir/DMA_IOMMU_PicoRV32_VC707_Systolic_Image_DMA.xpr"]

if {![file exists $xpr]} {
    error "Project not found: $xpr. Run create_vc707_systolic_image_dma_project.tcl first."
}

open_project $xpr
set_property top tb_soc_systolic_image_dma [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
# Elaborate without advancing time, then disable waveform capture.  Logging the
# complete PicoRV32/AXI hierarchy makes this long image regression needlessly
# slow and does not affect the self-checking result.
set_property xsim.simulate.runtime {0 ns} [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
catch {remove_wave [get_waves *]}
run all
catch {close_sim -force}
close_project

set log_file [file join $root_dir "reports/systolic_image_dma_soc_test.log"]
if {![file exists $log_file]} {
    error "Self-checking simulation did not create $log_file"
}
set fd [open $log_file r]
set contents [read $fd]
close $fd
if {[string first "SYSTOLIC IMAGE DMA SOC TEST PASSED" $contents] < 0} {
    error "Self-checking simulation did not report PASS"
}
puts $contents
