# Run CPU/SoC and full DMA/IOMMU AXI self-checks from one Vivado project.
set script_dir [file dirname [file normalize [info script]]]
if {[info exists ::env(DMA_PROJECT_ROOT)]
        && $::env(DMA_PROJECT_ROOT) ne ""} {
    set root_dir $::env(DMA_PROJECT_ROOT)
} else {
    set root_dir [file normalize [file join $script_dir ".."]]
}
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
    catch {close_sim}
    catch {close_project}
    open_project $xpr_file
}

source [file join $script_dir "ensure_descriptor_queue_sources.tcl"]
ensure_descriptor_queue_sources $root_dir

file mkdir [file join $root_dir "reports"]
set_property top tb_dma_iommu_picorv32_unified [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
# The complete firmware/RTL regression currently completes in about 185 us.
set_property xsim.simulate.runtime {2 ms} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
file copy -force [file join $project_dir \
    "DMA_IOMMU_PicoRV32_Unified.sim/sim_1/behav/xsim/simulate.log"] \
    [file join $root_dir "reports/xsim_unified_regression.log"]
close_sim
puts "Unified simulation finished. Check Project_Vivado/reports/unified_verification.log."
