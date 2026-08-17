# Synthesis check for the 256-KiB VC707 image/DMA/Systolic project.
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
set status [get_property STATUS [get_runs synth_1]]
puts "SYNTHESIS STATUS: $status"
if {![string match "*Complete*" $status]} {
    error "Synthesis failed; inspect [get_property DIRECTORY [get_runs synth_1]]/runme.log"
}
close_project
exit 0
