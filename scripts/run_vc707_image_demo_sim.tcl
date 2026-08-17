set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ".."]]
set xpr [file join $root_dir \
    "build/vivado/vc707_image_demo/DMA_IOMMU_PicoRV32_VC707_Image_Demo.xpr"]
open_project $xpr
set_property top tb_soc_image_uart_demo [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
close_sim
close_project
