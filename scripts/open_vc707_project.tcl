# Open (or create) the dedicated VC707 project.
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
set project_dir [file join $root_dir "build/vivado/vc707"]
set xpr_file [file join $project_dir "DMA_IOMMU_PicoRV32_VC707.xpr"]

catch {close_sim}
catch {close_project}
if {![file exists $xpr_file]} {
    source [file join $script_dir "create_vc707_project.tcl"]
} else {
    open_project $xpr_file
}
puts "Opened VC707 project: $xpr_file"

