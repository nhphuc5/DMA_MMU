# Open the only project that should be used from now on.
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
if {[info exists ::env(DMA_PROJECT_OUT_DIR)]
        && $::env(DMA_PROJECT_OUT_DIR) ne ""} {
    set project_dir [file normalize $::env(DMA_PROJECT_OUT_DIR)]
} else {
    set project_dir [file join $root_dir "build/vivado/unified"]
}
set xpr_file [file join $project_dir "DMA_IOMMU_PicoRV32_Unified.xpr"]

catch {close_sim}
catch {close_project}
if {![file exists $xpr_file]} {
    source [file join $script_dir "create_unified_project.tcl"]
} else {
    open_project $xpr_file
}
source [file join $script_dir "ensure_descriptor_queue_sources.tcl"]
ensure_descriptor_queue_sources $root_dir

# A Vivado run can be left in ERROR when its generated launch Tcl is removed
# or when the GUI is closed while the run is being prepared.  Reset only
# failed runs here so the next Run Synthesis/Implementation regenerates all
# launch files; successful checkpoints are preserved.
foreach run_name [list synth_1 impl_1] {
    set run_obj [get_runs -quiet $run_name]
    if {[llength $run_obj] != 0} {
        set run_status [get_property STATUS $run_obj]
        if {[string match -nocase "*error*" $run_status] ||
            [string match -nocase "*fail*" $run_status]} {
            puts "Resetting failed Vivado run $run_name ($run_status)"
            reset_run $run_obj
        }
    }
}
foreach tb_name [list tb_dma_mmu_axi_top.sv tb_dma_mmu_picorv32_soc.sv \
                      tb_dma_iommu_picorv32_unified.sv] {
    set tb_file [get_files -quiet $tb_name]
    if {$tb_file ne ""} {
        set_property used_in_synthesis false $tb_file
        set_property used_in_implementation false $tb_file
        set_property used_in_simulation true $tb_file
    }
}
set_property top dma_mmu_picorv32_soc [get_filesets sources_1]
set_property top tb_dma_iommu_picorv32_unified [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "Opened unified CPU + DMA/IOMMU + AXI project: $xpr_file"
