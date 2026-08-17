# Create the VC707 hardware project without modifying the verified Artix-7
# project.  The design uses internal 64-KiB AXI BRAM; DDR3 is intentionally
# outside this first board target.

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
if {![info exists project_name]} {
    set project_name "DMA_IOMMU_PicoRV32_VC707"
}
if {![info exists output_subdir]} {
    set output_subdir "vc707"
}
if {![info exists firmware_subdir]} {
    set firmware_subdir "vc707"
}
if {![info exists firmware_program]} {
    set firmware_program "soc_demo"
}
if {![info exists firmware_hex_name]} {
    set firmware_hex_name "$firmware_program.hex"
}
if {![info exists soc_axi_addr_width]} {
    set soc_axi_addr_width 16
}
if {![info exists simulation_top]} {
    set simulation_top "tb_dma_iommu_picorv32_unified"
}
set out_dir    [file join $root_dir "build/vivado/$output_subdir"]
set part_name  "xc7vx485tffg1761-2"

if {[llength [get_parts -quiet $part_name]] == 0} {
    error "Virtex-7 support is not installed: Vivado cannot find $part_name"
}

set fw_file [file normalize \
    [file join $root_dir "firmware/build/$firmware_subdir/$firmware_hex_name"]]
if {![file exists $fw_file]} {
    error "Missing VC707 firmware: $fw_file. Build the selected firmware target first."
}

catch {close_sim}
catch {close_project}
file mkdir $out_dir
create_project -force $project_name $out_dir -part $part_name

# Board files are optional because the project uses the exact part and an
# explicit board XDC.  Use them when the local Vivado installation has them.
set vc707_boards [get_board_parts -quiet *vc707*]
if {[llength $vc707_boards] != 0} {
    set_property board_part [lindex $vc707_boards 0] [current_project]
    puts "Using optional VC707 board definition: [lindex $vc707_boards 0]"
}

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
    [file join $root_dir "src/UART/uart_apb_axis.sv"] \
    [file join $root_dir "src/AXI/axil_to_apb_bridge.sv"] \
    [file join $root_dir "src/Systolic/systolic_matmul_4x4.sv"] \
    [file join $root_dir "src/Systolic/systolic_accel_axil.sv"] \
    [file join $root_dir "src/Systolic/systolic_accel_axil_axis.sv"] \
    [file join $root_dir "src/SoC/dma_mmu_axi_top.sv"] \
    [file join $root_dir "src/SoC/dma_mmu_picorv32_soc.sv"] \
    [file join $root_dir "src/SoC/dma_mmu_picorv32_vc707_top.sv"] \
]

foreach f $design_files {
    if {![file exists $f]} {
        error "Missing design source: $f"
    }
}
add_files -fileset sources_1 -norecurse $design_files

add_files -norecurse $fw_file
set_property file_type {Memory Initialization Files} \
    [get_files [file tail $fw_file]]

set_property top dma_mmu_picorv32_vc707_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property generic "MEM_INIT_FILE=$fw_file SOC_AXI_ADDR_WIDTH=$soc_axi_addr_width" \
    [get_filesets sources_1]

set xdc_file [file join $root_dir "constraints/dma_mmu_picorv32_vc707.xdc"]
add_files -fileset constrs_1 -norecurse $xdc_file

# Reuse the self-checking functional regressions.  They instantiate the
# board-independent SoC and use the fast simulation firmware, while synthesis
# and implementation use the VC707 wrapper and hardware firmware above.
set simulation_files [list \
    [file join $root_dir "testbench/tb_dma_mmu_axi_top.sv"] \
    [file join $root_dir "testbench/tb_dma_mmu_picorv32_soc.sv"] \
    [file join $root_dir "testbench/tb_picorv32_cpu_mmu.sv"] \
    [file join $root_dir "testbench/tb_dma_iommu_picorv32_unified.sv"] \
    [file join $root_dir "testbench/tb_uart_file_to_memory.sv"] \
    [file join $root_dir "testbench/tb_systolic_accel_axil.sv"] \
    [file join $root_dir "testbench/tb_systolic_accel_axil_axis.sv"] \
    [file join $root_dir "testbench/tb_soc_systolic_demo.sv"] \
    [file join $root_dir "testbench/tb_soc_systolic_image_dma.sv"] \
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
set_property top $simulation_top [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property xsim.simulate.runtime {2 ms} [get_filesets sim_1]

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property target_simulator XSim [current_project]

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
    [get_runs impl_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Created VC707 project: [file join $out_dir $project_name.xpr]"
puts "Device: $part_name"
puts "Hardware top: dma_mmu_picorv32_vc707_top"
puts "AXI BRAM address width: $soc_axi_addr_width bits ([expr {1 << $soc_axi_addr_width}] bytes)"
puts "Functional simulation top: $simulation_top"
puts "VC707 clock: 200 MHz differential input -> MMCM -> 150 MHz SoC clock"
