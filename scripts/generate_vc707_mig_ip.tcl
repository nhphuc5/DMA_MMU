# Create the official 7-series MIG from the tracked VC707 1-GiB SODIMM
# configuration. Output products are generated inside the active Vivado
# project so a fresh clone does not depend on machine-specific cache files.
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ".."]]
set mig_prj [file join $root_dir "ip/vc707_mig_7series/mig.prj"]

if {![file exists $mig_prj]} {
    error "Missing tracked MIG configuration: $mig_prj"
}
if {[current_project -quiet] eq ""} {
    error "generate_vc707_mig_ip.tcl requires an open Vivado project"
}

set mig_name vc707_mig
if {[llength [get_ips -quiet $mig_name]] == 0} {
    create_ip -name mig_7series -vendor xilinx.com -library ip \
        -version 4.2 -module_name $mig_name
}
set_property -dict [list CONFIG.XML_INPUT_FILE $mig_prj] [get_ips $mig_name]
generate_target all [get_ips $mig_name]
puts "Generated MIG IP $mig_name from $mig_prj"

# The SoC memory bus is 32-bit at 150 MHz while MIG exposes a 512-bit AXI4
# slave at its 200-MHz ui_clk. A dedicated clock converter crosses the CDC;
# the following synchronous width converter then upsizes 32 to 512 bits.
set clock_converter_name soc_ddr_clock_converter
if {[llength [get_ips -quiet $clock_converter_name]] == 0} {
    create_ip -name axi_clock_converter -vendor xilinx.com -library ip \
        -version 2.1 -module_name $clock_converter_name
}
set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.ID_WIDTH {6} \
    CONFIG.ACLK_ASYNC {1} \
    CONFIG.SYNCHRONIZATION_STAGES {3} \
    CONFIG.SI_CLK.FREQ_HZ {150000000} \
    CONFIG.MI_CLK.FREQ_HZ {200000000} \
] [get_ips $clock_converter_name]
generate_target all [get_ips $clock_converter_name]
puts "Generated AXI clock converter $clock_converter_name (150 -> 200 MHz)"

set converter_name soc_ddr_axi_converter
if {[llength [get_ips -quiet $converter_name]] == 0} {
    create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
        -version 2.1 -module_name $converter_name
}
set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.SI_DATA_WIDTH {32} \
    CONFIG.MI_DATA_WIDTH {512} \
    CONFIG.SI_ID_WIDTH {6} \
    CONFIG.ACLK_ASYNC {0} \
    CONFIG.SI_CLK.FREQ_HZ {200000000} \
    CONFIG.MI_CLK.FREQ_HZ {200000000} \
] [get_ips $converter_name]
generate_target all [get_ips $converter_name]
puts "Generated AXI width converter $converter_name (32 -> 512 at 200 MHz)"
