# Dedicated VC707 image -> DMA -> systolic -> DMA -> BRAM -> UART target.
# The legacy 64-KiB projects retain their original default parameters.
set project_name "DMA_IOMMU_PicoRV32_VC707_Systolic_Image_DMA"
# An optional first Tcl argument selects an independent build directory.  This
# is useful for automated regressions while the normal Vivado GUI project is
# open (Vivado otherwise locks its simulation log/database files).
if {$argc > 0} {
    set output_subdir [lindex $argv 0]
} else {
    set output_subdir "vc707_systolic_image_dma"
}
set firmware_subdir "vc707_systolic_image_dma"
set firmware_program "soc_systolic_image_dma"
set firmware_hex_name "soc_systolic_image_dma_with_image.hex"
set soc_axi_addr_width 18
set simulation_top "tb_soc_systolic_image_dma"

source [file join [file dirname [file normalize [info script]]] \
    "create_vc707_project.tcl"]

# Simulation uses the fast-UART firmware image but the same 256-KiB RAM map.
set sim_fw [file normalize [file join $root_dir \
    "firmware/build/systolic_image_dma/soc_systolic_image_dma_with_image.hex"]]
set sim_expected [file normalize [file join $root_dir \
    "firmware/build/systolic_image_dma/assets/expected_output_64x64.hex8"]]
if {![file exists $sim_fw] || ![file exists $sim_expected]} {
    error "Missing simulation image assets. Run: make systolic-image-dma"
}
set_property generic "MEM_INIT_FILE=$sim_fw EXPECTED_FILE=$sim_expected" \
    [get_filesets sim_1]
set_property xsim.simulate.runtime {10 ms} [get_filesets sim_1]
update_compile_order -fileset sim_1
