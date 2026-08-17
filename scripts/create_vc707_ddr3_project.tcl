# Create the complete physical-DDR3 VC707 project.  This wrapper selects the
# MIG-backed top and reuses the common, tested SoC source/project definition.
set script_dir [file dirname [file normalize [info script]]]
set project_name "DMA_IOMMU_PicoRV32_VC707_DDR3"
set output_subdir "vc707_ddr3"
set firmware_subdir "vc707_ddr3"
set firmware_program "soc_ddr3_test"
set firmware_hex_name "soc_ddr3_test.hex"
set firmware_hex_file "firmware/prebuilt/vc707_ddr3/soc_ddr3_test.hex"
set soc_axi_addr_width 32
set hardware_top "dma_mmu_picorv32_vc707_ddr3_top"
set hardware_top_source "src/SoC/dma_mmu_picorv32_vc707_ddr3_top.sv"
set board_xdc "constraints/dma_mmu_picorv32_vc707_ddr3.xdc"
set generate_vc707_mig 1
set include_simulation_files 0
source [file join $script_dir "create_vc707_project.tcl"]
