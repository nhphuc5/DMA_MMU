# End-to-end UART -> DMA/IOMMU -> external DDR model -> systolic -> UART test.
set script_dir [file dirname [file normalize [info script]]]
if {[info exists ::env(DMA_PROJECT_ROOT)] && $::env(DMA_PROJECT_ROOT) ne ""} {
    set root_dir $::env(DMA_PROJECT_ROOT)
} else {
    set root_dir [file normalize [file join $script_dir ".."]]
}
if {![info exists ::env(DMA_PROJECT_OUT_DIR)]
        || $::env(DMA_PROJECT_OUT_DIR) eq ""} {
    set ::env(DMA_PROJECT_OUT_DIR) [file join $root_dir "build/vivado/vc707_unified_batch_sim"]
}

source [file join $script_dir "create_unified_project.tcl"]

set tb_file [file join $root_dir "testbench/tb_soc_uart_image_batch.sv"]
set fw_file [file join $root_dir "firmware/prebuilt/vc707_unified/soc_uart_image_batch.hex"]
if {![file exists $tb_file] || ![file exists $fw_file]} {
    error "Missing unified batch testbench or firmware image"
}
add_files -fileset sim_1 -norecurse $tb_file
set_property file_type SystemVerilog [get_files $tb_file]
if {[llength [get_files -quiet $fw_file]] == 0} {
    add_files -norecurse $fw_file
    set_property file_type {Memory Initialization Files} [get_files $fw_file]
}
set_property top tb_soc_uart_image_batch [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property generic "MEM_INIT_FILE=$fw_file EXPECTED_DMA_MODE=0" [get_filesets sim_1]
set_property xsim.simulate.runtime {20 ms} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
file mkdir [file join $root_dir "reports/vc707_unified_ddr3"]
file copy -force [file join $::env(DMA_PROJECT_OUT_DIR) \
    "DMA_IOMMU_PicoRV32_Unified.sim/sim_1/behav/xsim/simulate.log"] \
    [file join $root_dir "reports/vc707_unified_ddr3/xsim_uart_dma_ddr_systolic.log"]
close_sim
puts "VC707 unified UART/DMA/DDR/systolic simulation complete"
