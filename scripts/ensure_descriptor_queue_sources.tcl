# Keep an existing Vivado project compatible with the descriptor-queue,
# CPU-authorized-access, and CPU-MMU upgrades.  New projects already include
# these files; this helper adds them when an older .xpr is reused.

proc ensure_descriptor_queue_sources {root_dir} {
    set queue_files [list \
        [file normalize [file join $root_dir "src/DMA/dma_descriptor_fifo.sv"]] \
        [file normalize [file join $root_dir "src/DMA/dma_completion_fifo.sv"]] \
        [file normalize [file join $root_dir "src/DMA/dma_access_controller.sv"]] \
        [file normalize [file join $root_dir "src/PicoRV32/picorv32_cpu_mmu.sv"]]]

    foreach f $queue_files {
        if {![file exists $f]} {
            error "Missing DMA upgrade source: $f"
        }

        # get_files $f can also discover an out-of-project file through the
        # hierarchy parser, so it is not a reliable membership test.  Compare
        # only files that are actually owned by sources_1.
        set present_in_sources 0
        foreach project_file [get_files -quiet -of_objects \
                                  [get_filesets sources_1]] {
            set project_name [file normalize [get_property NAME $project_file]]
            if {$project_name eq $f} {
                set present_in_sources 1
                break
            }
        }
        if {!$present_in_sources} {
            puts "Adding DMA upgrade source to existing project: $f"
            add_files -fileset sources_1 -norecurse $f
        }
        set queue_object [get_files -quiet -of_objects [get_filesets sources_1] \
                              [file tail $f]]
        if {[llength $queue_object] == 0} {
            error "DMA upgrade source was not added to sources_1: $f"
        }
        set_property FILE_TYPE SystemVerilog $queue_object
        set_property USED_IN_SYNTHESIS true $queue_object
        set_property USED_IN_IMPLEMENTATION true $queue_object
        set_property USED_IN_SIMULATION true $queue_object
    }

    set cpu_mmu_tb [file normalize [file join $root_dir \
                        "testbench/tb_picorv32_cpu_mmu.sv"]]
    if {[file exists $cpu_mmu_tb]} {
        set present_in_sim 0
        foreach project_file [get_files -quiet -of_objects [get_filesets sim_1]] {
            if {[file normalize [get_property NAME $project_file]] eq $cpu_mmu_tb} {
                set present_in_sim 1
                break
            }
        }
        if {!$present_in_sim} {
            puts "Adding CPU MMU testbench to existing project: $cpu_mmu_tb"
            add_files -fileset sim_1 -norecurse $cpu_mmu_tb
        }
        set cpu_mmu_tb_object [get_files -quiet -of_objects \
            [get_filesets sim_1] [file tail $cpu_mmu_tb]]
        if {[llength $cpu_mmu_tb_object] == 0} {
            error "CPU MMU testbench was not added to sim_1: $cpu_mmu_tb"
        }
        set_property FILE_TYPE SystemVerilog $cpu_mmu_tb_object
    }
    # The complete firmware-driven D01-D09 and descriptor-queue regression
    # takes about 185 us, so a 100 us launch would stop before PASS is emitted.
    set_property xsim.simulate.runtime {2 ms} [get_filesets sim_1]
    update_compile_order -fileset sources_1
}
