# Rebuild and run the byte-exact 50 KiB UART -> DMA -> RAM regression.

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
set input_file [file normalize [file join $root_dir "testdata/uart_input_50k.txt"]]
set log_file   [file normalize [file join $root_dir "reports/uart_file_to_memory_50k.log"]]
set tb_file    [file normalize [file join $root_dir "testbench/tb_uart_file_to_memory.sv"]]
set out_dir    [file normalize [file join $root_dir "build/vivado/uart_file_transfer"]]

if {![file exists $input_file]} {
    error "Missing 50 KiB UART input: run scripts/generate_uart_50k_testfile.py first"
}
if {[file size $input_file] != 51200} {
    error "UART input must be exactly 51200 bytes; got [file size $input_file]"
}

set ::env(DMA_PROJECT_OUT_DIR) $out_dir
source [file join $script_dir "create_unified_project.tcl"]
unset ::env(DMA_PROJECT_OUT_DIR)

if {[llength [get_files -quiet $tb_file]] == 0} {
    add_files -fileset sim_1 -norecurse $tb_file
}
set_property file_type SystemVerilog [get_files $tb_file]
set_property used_in_synthesis false [get_files $tb_file]
set_property used_in_implementation false [get_files $tb_file]
set_property used_in_simulation true [get_files $tb_file]
set_property top tb_uart_file_to_memory [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property xsim.simulate.runtime {30 ms} [get_filesets sim_1]
set xsim_options \
    "-testplusarg UART_FILE=$input_file -testplusarg UART_LOG=$log_file"
set_property -name xsim.simulate.xsim.more_options -value $xsim_options \
    -objects [get_filesets sim_1]

update_compile_order -fileset sim_1
launch_simulation
close_sim
save_project_as DMA_UART_File_Transfer_50KiB $out_dir -force

puts "UART file-transfer regression completed."
puts "Project: [file join $out_dir DMA_UART_File_Transfer_50KiB.xpr]"
puts "Report : $log_file"
