# Create a dedicated VC707 project whose AXI RAM boots the matrix-multiply
# firmware.  The hardware remains the complete PicoRV32 + DMA/IOMMU + UART SoC
# and gains the memory-mapped systolic accelerator.
set script_dir [file dirname [file normalize [info script]]]
set project_name "DMA_IOMMU_PicoRV32_VC707_Systolic"
set output_subdir "vc707_systolic"
set firmware_subdir "vc707_systolic_demo"
set firmware_program "soc_systolic_demo"
set simulation_top "tb_soc_systolic_demo"
source [file join $script_dir "create_vc707_project.tcl"]

