set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
set xpr_file [file join $root_dir \
    "build/vivado/vc707_systolic/DMA_IOMMU_PicoRV32_VC707_Systolic.xpr"]

if {![file exists $xpr_file]} {
    source [file join $script_dir "create_vc707_systolic_project.tcl"]
} elseif {[current_project -quiet] eq ""} {
    open_project $xpr_file
}

set_property top tb_soc_systolic_demo [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property xsim.simulate.runtime {2 ms} [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
close_sim
close_project
exit 0

