# Run the DMA/IOMMU/AXI matrix and edge-case regression in an isolated XSim
# project.  This avoids locking the main GUI project when Vivado is open.
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
if {[info exists ::env(DMA_EDGE_OUT_DIR)]
        && $::env(DMA_EDGE_OUT_DIR) ne ""} {
    set out_dir [file normalize $::env(DMA_EDGE_OUT_DIR)]
} else {
    set out_dir [file join $root_dir "build/vivado/axi_edge_regression_verify"]
}

catch {close_sim}
catch {close_project}
create_project -force DMA_AXI_Edge_Regression $out_dir \
    -part xc7a35tcpg236-1

set design_files [list \
    [file join $root_dir "src/IOMMU/pseudoLRU.sv"] \
    [file join $root_dir "src/IOMMU/dma_iommu_tlb.sv"] \
    [file join $root_dir "src/DMA/dma_descriptor_fifo.sv"] \
    [file join $root_dir "src/DMA/dma_completion_fifo.sv"] \
    [file join $root_dir "src/DMA/dma_access_controller.sv"] \
    [file join $root_dir "src/DMA/dma_axil_regs.sv"] \
    [file join $root_dir "src/DMA/dma_axi_scheduler.sv"] \
    [file join $root_dir "src/DMA/axi_cdma.v"] \
    [file join $root_dir "src/DMA/axi_dma_rd.v"] \
    [file join $root_dir "src/DMA/axi_dma_wr.v"] \
    [file join $root_dir "src/AXI/priority_encoder.v"] \
    [file join $root_dir "src/AXI/arbiter.v"] \
    [file join $root_dir "src/AXI/axi_register_wr.v"] \
    [file join $root_dir "src/AXI/axi_register_rd.v"] \
    [file join $root_dir "src/AXI/axi_crossbar_addr.v"] \
    [file join $root_dir "src/AXI/axi_crossbar_wr.v"] \
    [file join $root_dir "src/AXI/axi_crossbar_rd.v"] \
    [file join $root_dir "src/AXI/axi_crossbar.v"] \
    [file join $root_dir "src/AXI/axi_ram.v"] \
    [file join $root_dir "src/SoC/dma_mmu_axi_top.sv"] \
]

add_files -fileset sources_1 -norecurse $design_files
foreach f [get_files -of_objects [get_filesets sources_1]] {
    set_property FILE_TYPE SystemVerilog $f
}

set tb_file [file join $root_dir "testbench/tb_dma_mmu_axi_top.sv"]
add_files -fileset sim_1 -norecurse $tb_file
set_property FILE_TYPE SystemVerilog [get_files $tb_file]
set_property top tb_dma_mmu_axi_top [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property target_simulator XSim [current_project]
set_property xsim.simulate.runtime {100 us} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
close_sim
close_project
puts "DMA/IOMMU/AXI edge regression completed."
