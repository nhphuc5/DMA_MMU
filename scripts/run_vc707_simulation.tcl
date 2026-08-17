# Run the complete self-checking functional regression from the VC707 project.
# The simulation intentionally uses the board-independent SoC top and fast
# UART divider; FPGA pins/MMCM are verified by synthesis/implementation.
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
set project_dir [file join $root_dir "build/vivado/vc707"]
set xpr_file [file join $project_dir "DMA_IOMMU_PicoRV32_VC707.xpr"]

if {![file exists $xpr_file]} {
    source [file join $script_dir "create_vc707_project.tcl"]
} elseif {[current_project -quiet] eq ""} {
    open_project $xpr_file
}

set_property top tb_dma_iommu_picorv32_unified [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property xsim.simulate.runtime {2 ms} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
run all
puts "VC707 project functional simulation finished."
puts "Result: [file join $root_dir reports/unified_verification.log]"
close_sim
close_project
exit 0
