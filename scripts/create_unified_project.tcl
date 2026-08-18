# Create the single Vivado project used for both implementation and verification.
# Synthesizable top: dma_mmu_picorv32_soc
# Simulation top:   tb_dma_iommu_picorv32_unified

set script_dir [file dirname [file normalize [info script]]]
if {[info exists ::env(DMA_PROJECT_ROOT)]
        && $::env(DMA_PROJECT_ROOT) ne ""} {
    set root_dir $::env(DMA_PROJECT_ROOT)
} else {
    set root_dir [file normalize [file join $script_dir ".."]]
}
if {[info exists ::env(DMA_PROJECT_OUT_DIR)]
        && $::env(DMA_PROJECT_OUT_DIR) ne ""} {
    set out_dir [file normalize $::env(DMA_PROJECT_OUT_DIR)]
} else {
    set out_dir [file join $root_dir "build/vivado/unified"]
}
set part_name  "xc7a35tcpg236-1"

catch {close_sim}
catch {close_project}
file mkdir $out_dir
create_project -force DMA_IOMMU_PicoRV32_Unified $out_dir -part $part_name

set design_files [list \
    [file join $root_dir "src/PicoRV32/picorv32.v"] \
    [file join $root_dir "src/PicoRV32/picorv32_axil_router.sv"] \
    [file join $root_dir "src/PicoRV32/picorv32_cpu_mmu.sv"] \
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
    [file join $root_dir "src/Memory/ddr3_controller_core.sv"] \
    [file join $root_dir "src/Memory/axi_ddr3_controller.sv"] \
    [file join $root_dir "src/Memory/axi_bram_ddr3_subsystem.sv"] \
    [file join $root_dir "src/UART/simpleuart_dma.sv"] \
    [file join $root_dir "src/UART/uart_axil_axis.sv"] \
    [file join $root_dir "src/Systolic/systolic_matmul_4x4.sv"] \
    [file join $root_dir "src/Systolic/systolic_accel_axil_axis.sv"] \
    [file join $root_dir "src/SoC/dma_mmu_axi_top.sv"] \
    [file join $root_dir "src/SoC/dma_mmu_picorv32_soc.sv"] \
]

foreach f $design_files {
    if {![file exists $f]} {
        error "Missing organized design source: $f"
    }
}

add_files -fileset sources_1 -norecurse $design_files
foreach f [get_files -of_objects [get_filesets sources_1]] {
    set_property FILE_TYPE SystemVerilog $f
}

set fw_file [file join $root_dir "firmware/build/soc_demo.hex"]
add_files -norecurse $fw_file
set_property file_type {Memory Initialization Files} \
    [get_files [file tail $fw_file]]

# Keeping this top unchanged preserves the high-frequency implementation.
set_property top dma_mmu_picorv32_soc [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property generic "MEM_INIT_FILE=$fw_file" [get_filesets sources_1]

add_files -fileset constrs_1 -norecurse \
    [file join $root_dir "constraints/dma_mmu_picorv32_soc.xdc"]

set simulation_files [list \
    [file join $root_dir "testbench/tb_dma_mmu_axi_top.sv"] \
    [file join $root_dir "testbench/tb_dma_mmu_picorv32_soc.sv"] \
    [file join $root_dir "testbench/tb_picorv32_cpu_mmu.sv"] \
    [file join $root_dir "testbench/tb_dma_iommu_picorv32_unified.sv"] \
    [file join $root_dir "testbench/tb_uart_file_to_memory.sv"] \
    [file join $root_dir "testbench/ddr3_dfi_memory_model.sv"] \
    [file join $root_dir "testbench/tb_axi_ddr3_controller.sv"] \
    [file join $root_dir "testbench/tb_axi_bram_ddr3_subsystem.sv"] \
]
add_files -fileset sim_1 -norecurse $simulation_files
foreach f $simulation_files {
    set_property file_type SystemVerilog [get_files $f]
    set_property used_in_synthesis false [get_files $f]
    set_property used_in_implementation false [get_files $f]
    set_property used_in_simulation true [get_files $f]
}
set_property top tb_dma_iommu_picorv32_unified [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property verilog_define {} [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property target_simulator XSim [current_project]
# The CPU-driven D01-D09 matrix plus the eight-entry descriptor queue
# completes in about 185 us.  Keep enough headroom for slower host machines.
set_property xsim.simulate.runtime {2 ms} [get_filesets sim_1]

# Timing-oriented strategies. Testbenches are simulation-only and do not enter
# synthesis, placement, or routing.
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
    [get_runs impl_1]

puts "Created unified project: [file join $out_dir DMA_IOMMU_PicoRV32_Unified.xpr]"
puts "Synthesis top: dma_mmu_picorv32_soc"
puts "Simulation top: tb_dma_iommu_picorv32_unified"
