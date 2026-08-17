# Isolated behavioral regression for the project-owned AXI DDR3 controller.
set script_dir [file dirname [file normalize [info script]]]
if {[info exists ::env(DDR3_PROJECT_ROOT)]
        && $::env(DDR3_PROJECT_ROOT) ne ""} {
    set root_dir $::env(DDR3_PROJECT_ROOT)
} else {
    set root_dir [file normalize [file join $script_dir ".."]]
}
if {[info exists ::env(DDR3_CONTROLLER_OUT_DIR)]
        && $::env(DDR3_CONTROLLER_OUT_DIR) ne ""} {
    set out_dir [file normalize $::env(DDR3_CONTROLLER_OUT_DIR)]
} else {
    set out_dir [file join $root_dir "build/vivado/ddr3_controller_regression"]
}

catch {close_sim}
catch {close_project}
create_project -force DDR3_Controller_Regression $out_dir \
    -part xc7vx485tffg1761-2

set design_files [list \
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
]
set sim_files [list \
    [file join $root_dir "testbench/ddr3_dfi_memory_model.sv"] \
    [file join $root_dir "testbench/tb_axi_ddr3_controller.sv"] \
    [file join $root_dir "testbench/tb_axi_bram_ddr3_subsystem.sv"] \
    [file join $root_dir "testbench/tb_axi_bram_external_ddr_subsystem.sv"] \
]
add_files -fileset sources_1 -norecurse $design_files
add_files -fileset sim_1 -norecurse $sim_files
foreach f [concat $design_files $sim_files] {
    set_property FILE_TYPE SystemVerilog [get_files $f]
}
set_property top tb_axi_ddr3_controller [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property target_simulator XSim [current_project]
set_property xsim.simulate.runtime {20 ms} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set report_dir [file join $root_dir "reports/ddr3_controller"]
file mkdir $report_dir
launch_simulation
file copy -force [file join $out_dir \
    "DDR3_Controller_Regression.sim/sim_1/behav/xsim/simulate.log"] \
    [file join $report_dir "xsim_controller_regression.log"]
close_sim
set_property top tb_axi_bram_ddr3_subsystem [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
file copy -force [file join $out_dir \
    "DDR3_Controller_Regression.sim/sim_1/behav/xsim/simulate.log"] \
    [file join $report_dir "xsim_bram_ddr_integration.log"]
close_sim
set_property top tb_axi_bram_external_ddr_subsystem [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
file copy -force [file join $out_dir \
    "DDR3_Controller_Regression.sim/sim_1/behav/xsim/simulate.log"] \
    [file join $report_dir "xsim_external_mig_bridge.log"]
close_sim
close_project
puts "DDR3 controller, BRAM integration and external MIG bridge XSim regressions completed."
