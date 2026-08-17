# Package the project-owned AXI DDR3 digital controller as reusable Vivado IP.
# The generated IP deliberately exposes the DFI-lite/calibration boundary;
# a board-specific DDR PHY must be connected outside this package.
set script_dir [file dirname [file normalize [info script]]]
if {[info exists ::env(DDR3_PROJECT_ROOT)]
        && $::env(DDR3_PROJECT_ROOT) ne ""} {
    set root_dir $::env(DDR3_PROJECT_ROOT)
} else {
    set root_dir [file normalize [file join $script_dir ".."]]
}
if {[info exists ::env(DDR3_IP_OUT_DIR)]
        && $::env(DDR3_IP_OUT_DIR) ne ""} {
    set ip_root [file normalize $::env(DDR3_IP_OUT_DIR)]
} else {
    set ip_root [file join $root_dir "ip_repo/axi_ddr3_controller_1_0"]
}
if {[info exists ::env(DDR3_SYNTH_PART)]
        && $::env(DDR3_SYNTH_PART) ne ""} {
    set part_name $::env(DDR3_SYNTH_PART)
} else {
    set part_name "xc7vx485tffg1761-2"
}
set work_dir [file join $root_dir "build/vivado/ddr3_controller_package"]
file mkdir [file dirname $ip_root]
file mkdir [file dirname $work_dir]

catch {close_project}
create_project -force DDR3_Controller_Package $work_dir -part $part_name
add_files -norecurse [list \
    [file join $root_dir "src/Memory/ddr3_controller_core.sv"] \
    [file join $root_dir "src/Memory/axi_ddr3_controller.sv"] \
]
foreach f [get_files -of_objects [get_filesets sources_1]] {
    set_property FILE_TYPE SystemVerilog $f
}
set_property top axi_ddr3_controller [get_filesets sources_1]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_root -vendor user.org \
    -library memory -taxonomy /Memory_Elements -import_files -force
set core [ipx::current_core]
set_property name axi_ddr3_controller $core
set_property display_name {Project AXI DDR3 Controller (DFI-lite)} $core
set_property description \
    {AXI4 DDR3 command controller with initialization, refresh, bank/row tracking, and an exposed board-PHY boundary.} $core
set_property vendor_display_name {Project Local IP} $core
set_property version 1.0 $core
set_property core_revision 1 $core
set_property supported_families \
    {artix7 Production virtex7 Production kintex7 Production} $core

# Standard S_AXI/aclk/aresetn names are inferred by package_project, including
# ASSOCIATED_BUSIF and ASSOCIATED_RESET on the clock bus interface.
set clk_if [ipx::get_bus_interfaces -quiet aclk -of_objects $core]
if {[llength $clk_if] != 0
        && [llength [ipx::get_bus_parameters -quiet FREQ_HZ \
                         -of_objects $clk_if]] == 0} {
    set freq_parameter [ipx::add_bus_parameter FREQ_HZ $clk_if]
    set_property value 150000000 $freq_parameter
    set_property value_resolve_type user $freq_parameter
}
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -quiet $core
ipx::save_core $core
puts "Packaged DDR3 controller IP: [file join $ip_root component.xml]"
close_project
