# Create a VC707 hardware project without modifying the verified Artix-7
# project.  Defaults select the BRAM-only target; wrappers can select the
# complete MIG-backed physical DDR3 target.

set script_dir [file dirname [file normalize [info script]]]
if {[info exists ::env(VC707_PROJECT_ROOT)]
        && $::env(VC707_PROJECT_ROOT) ne ""} {
    # Keep the caller-provided spelling.  This also permits a Windows junction
    # when the checkout path itself contains characters Vivado disallows in a
    # project directory name.
    set root_dir $::env(VC707_PROJECT_ROOT)
} else {
    set root_dir [file normalize [file join $script_dir ".."]]
}
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
if {![info exists firmware_hex_file]} {
    set firmware_hex_file "firmware/build/$firmware_subdir/$firmware_hex_name"
}
if {![info exists soc_axi_addr_width]} {
    set soc_axi_addr_width 16
}
if {![info exists simulation_top]} {
    set simulation_top "tb_dma_iommu_picorv32_unified"
}
if {![info exists hardware_top]} {
    set hardware_top "dma_mmu_picorv32_vc707_top"
}
if {![info exists hardware_top_source]} {
    set hardware_top_source "src/SoC/dma_mmu_picorv32_vc707_top.sv"
}
if {![info exists board_xdc]} {
    set board_xdc "constraints/dma_mmu_picorv32_vc707.xdc"
}
if {![info exists generate_vc707_mig]} {
    set generate_vc707_mig 0
}
if {![info exists include_simulation_files]} {
    set include_simulation_files 1
}
set out_dir    [file join $root_dir "build/vivado/$output_subdir"]
set part_name  "xc7vx485tffg1761-2"

if {[llength [get_parts -quiet $part_name]] == 0} {
    error "Virtex-7 support is not installed: Vivado cannot find $part_name"
}

set fw_file [file join $root_dir $firmware_hex_file]
if {![info exists ::env(VC707_PROJECT_ROOT)]
        || $::env(VC707_PROJECT_ROOT) eq ""} {
    set fw_file [file normalize $fw_file]
}
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
    [file join $root_dir "src/UART/uart_axil_axis.sv"] \
    [file join $root_dir "src/Systolic/systolic_matmul_4x4.sv"] \
    [file join $root_dir "src/Systolic/systolic_accel_axil.sv"] \
    [file join $root_dir "src/Systolic/systolic_accel_axil_axis.sv"] \
    [file join $root_dir "src/SoC/dma_mmu_axi_top.sv"] \
    [file join $root_dir "src/SoC/dma_mmu_picorv32_soc.sv"] \
]
lappend design_files [file join $root_dir $hardware_top_source]

foreach f $design_files {
    if {![file exists $f]} {
        error "Missing design source: $f"
    }
}
add_files -fileset sources_1 -norecurse $design_files

if {$generate_vc707_mig} {
    source [file join $script_dir "generate_vc707_mig_ip.tcl"]
}

add_files -norecurse $fw_file
set_property file_type {Memory Initialization Files} \
    [get_files [file tail $fw_file]]

set_property top $hardware_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
if {$hardware_top eq "dma_mmu_picorv32_vc707_top"} {
    set_property generic "MEM_INIT_FILE=$fw_file SOC_AXI_ADDR_WIDTH=$soc_axi_addr_width" \
        [get_filesets sources_1]
} else {
    set_property generic "MEM_INIT_FILE=$fw_file" [get_filesets sources_1]
}

set xdc_file [file join $root_dir $board_xdc]
if {[info exists ::env(VC707_PROJECT_ROOT)]
        && $::env(VC707_PROJECT_ROOT) ne ""} {
    # Vivado rejects '(' and ')' specifically for constraint-file names even
    # when sources through the same junction are accepted.  Stage a generated
    # copy beside the project when a caller supplied an alternate root path.
    set staged_xdc [file join $out_dir [file tail $xdc_file]]
    file copy -force $xdc_file $staged_xdc
    set xdc_file $staged_xdc
}
add_files -fileset constrs_1 -norecurse $xdc_file
if {$generate_vc707_mig} {
    # This board XDC contains only pin/electrical settings and asynchronous
    # timing exceptions.  MIG contributes all clock constraints separately.
    set_property USED_IN_SYNTHESIS false [get_files $xdc_file]
}

# Reuse the self-checking functional regressions.  They instantiate the
# board-independent SoC and use the fast simulation firmware, while synthesis
# and implementation use the VC707 wrapper and hardware firmware above.
if {$include_simulation_files} {
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
}

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property target_simulator XSim [current_project]

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
    [get_runs impl_1]

update_compile_order -fileset sources_1
if {$include_simulation_files} {
    update_compile_order -fileset sim_1
}

puts "Created VC707 project: [file join $out_dir $project_name.xpr]"
puts "Device: $part_name"
puts "Hardware top: $hardware_top"
puts "SoC AXI address width: $soc_axi_addr_width bits"
puts "Functional simulation top: $simulation_top"
puts "VC707 clock: 200 MHz differential input -> MMCM -> 150 MHz SoC clock"
