# Create a dedicated VC707 image-to-UART project from the already verified
# VC707 hardware project.  The original project and soc_demo firmware remain
# untouched.

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
set base_xpr   [file join $root_dir "build/vivado/vc707/DMA_IOMMU_PicoRV32_VC707.xpr"]
set out_dir    [file join $root_dir "build/vivado/vc707_image_demo"]
set image_hex  [file normalize [file join $root_dir \
    "firmware/build/vc707_image_demo/soc_image_demo_with_images.hex"]]
set tb_file    [file normalize [file join $root_dir \
    "testbench/tb_soc_image_uart_demo.sv"]]

if {![file exists $base_xpr]} {
    error "Missing verified base project: $base_xpr"
}
if {![file exists $image_hex]} {
    error "Missing image RAM HEX: $image_hex. Run firmware/build_vc707_image_demo.cmd."
}
if {![file exists $tb_file]} {
    error "Missing image self-checking testbench: $tb_file"
}

catch {close_sim}
catch {close_project}
open_project $base_xpr
file mkdir $out_dir
save_project_as -force DMA_IOMMU_PicoRV32_VC707_Image_Demo $out_dir

add_files -norecurse $image_hex
set_property file_type {Memory Initialization Files} [get_files $image_hex]
set_property generic "MEM_INIT_FILE=$image_hex" [get_filesets sources_1]

add_files -fileset sim_1 -norecurse $tb_file
set_property file_type SystemVerilog [get_files $tb_file]
set_property used_in_synthesis false [get_files $tb_file]
set_property used_in_implementation false [get_files $tb_file]
set_property used_in_simulation true [get_files $tb_file]
set_property top tb_soc_image_uart_demo [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property xsim.simulate.runtime {12 ms} [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
# Vivado project-mode commands persist source-set properties directly in the
# .xpr.  close_project flushes the final state; there is no save_project Tcl
# command (Vivado otherwise interprets it as an incomplete save_project_as).
close_project

puts "Created image demo project: [file join $out_dir DMA_IOMMU_PicoRV32_VC707_Image_Demo.xpr]"
puts "Hardware RAM image: $image_hex"
puts "Simulation top: tb_soc_image_uart_demo"
