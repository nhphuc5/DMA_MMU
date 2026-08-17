# Produce separate post-route internal timing/Fmax estimates for the DMA and
# IOMMU portions of the unified SoC.  Endpoints are restricted to registers
# inside each named hierarchy, so CPU/UART/RAM paths are not included.

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
if {[info exists ::env(DMA_PROJECT_OUT_DIR)]
        && $::env(DMA_PROJECT_OUT_DIR) ne ""} {
    set project_dir [file normalize $::env(DMA_PROJECT_OUT_DIR)]
} else {
    set project_dir [file join $root_dir "build/vivado/unified"]
}
set xpr_file [file join $project_dir "DMA_IOMMU_PicoRV32_Unified.xpr"]
set report_dir [file join $root_dir "reports"]
file mkdir $report_dir

if {![file exists $xpr_file]} {
    source [file join $script_dir "create_unified_project.tcl"]
} elseif {[current_project -quiet] eq "" || \
          [file normalize [get_property DIRECTORY [current_project]]] ne \
          [file normalize [file dirname $xpr_file]]} {
    catch {close_project}
    open_project $xpr_file
}

source [file join $script_dir "ensure_descriptor_queue_sources.tcl"]
ensure_descriptor_queue_sources $root_dir

set impl_status [get_property STATUS [get_runs impl_1]]
set impl_refresh [get_property NEEDS_REFRESH [get_runs impl_1]]
if {$impl_refresh || ![string match "*Complete*" $impl_status]} {
    puts "Implementation is not current; running unified implementation first."
    source [file join $script_dir "run_unified_implementation.tcl"]
    # run_unified_implementation.tcl generates this report at its end.
    return
}
open_run impl_1

set clocks [get_clocks -quiet sys_clk]
if {[llength $clocks] == 0} {
    error "Clock sys_clk was not found in the implemented design."
}
set clock_period_ns [get_property PERIOD $clocks]

proc collect_group_registers {patterns} {
    set result ""
    foreach pattern $patterns {
        set found [get_cells -hier -quiet -filter \
            "IS_SEQUENTIAL == 1 && NAME =~ $pattern"]
        if {[llength $found] != 0} {
            if {$result eq ""} {
                set result $found
            } else {
                # Vivado 2025.1 represents this query result as a Tcl list;
                # merge by object name instead of using add_to_collection.
                set result [lsort -unique [concat $result $found]]
            }
        }
    }
    return $result
}

proc safe_path_property {path property fallback} {
    if {[catch {set value [get_property $property $path]}]} {
        return $fallback
    }
    if {$value eq ""} {
        return $fallback
    }
    return $value
}

proc write_group_result {fd group_name scope_text regs period_ns rpt_path} {
    puts $fd "------------------------------------------------------------"
    puts $fd "CORE: $group_name"
    puts $fd "Scope: $scope_text"
    puts $fd "Sequential cells in scope: [llength $regs]"

    if {[llength $regs] == 0} {
        puts $fd "ERROR: no registers found for this hierarchy."
        return
    }

    set path [get_timing_paths -quiet -from $regs -to $regs \
        -delay_type max -max_paths 1 -nworst 1]
    if {[llength $path] == 0} {
        puts $fd "ERROR: no internal register-to-register timing path found."
        return
    }

    set slack_ns [get_property SLACK $path]
    set critical_period_ns [expr {$period_ns - $slack_ns}]
    set fmax_mhz [expr {1000.0 / $critical_period_ns}]
    set startpoint [safe_path_property $path STARTPOINT_PIN "not available"]
    set endpoint [safe_path_property $path ENDPOINT_PIN "not available"]
    set logic_levels [safe_path_property $path LOGIC_LEVELS "not available"]

    puts $fd [format "Reference clock constraint : %.3f ns (%.3f MHz)" \
        $period_ns [expr {1000.0/$period_ns}]]
    puts $fd [format "Worst internal slack       : %.3f ns" $slack_ns]
    puts $fd [format "Equivalent critical period : %.3f ns" $critical_period_ns]
    puts $fd [format "Estimated isolated Fmax    : %.3f MHz" $fmax_mhz]
    puts $fd "Formula                     : Tcritical = Tconstraint - Slack"
    puts $fd [format "Substitution                : %.3f - %.3f = %.3f ns" \
        $period_ns $slack_ns $critical_period_ns]
    puts $fd "Formula                     : Fmax(MHz) = 1000 / Tcritical(ns)"
    puts $fd [format "Substitution                : 1000 / %.3f = %.3f MHz" \
        $critical_period_ns $fmax_mhz]
    puts $fd "Logic levels               : $logic_levels"
    puts $fd "Startpoint                 : $startpoint"
    puts $fd "Endpoint                   : $endpoint"
    puts $fd "Method: post-route register-to-register path constrained to this hierarchy."

    report_timing -from $regs -to $regs -delay_type max \
        -max_paths 20 -nworst 5 -file $rpt_path
}

# Full DMA core: scheduler, memory-to-memory engine, memory/stream engines,
# internal AXI crossbar, and the top-level M2S byte counter.  IOMMU, CPU,
# UART, system RAM, and shared system crossbar are deliberately excluded.
set dma_patterns [list \
    "*dma_iommu_inst/scheduler_inst/*" \
    "*dma_iommu_inst/cdma_inst/*" \
    "*dma_iommu_inst/dma_rd_inst/*" \
    "*dma_iommu_inst/dma_wr_inst/*" \
    "*dma_iommu_inst/crossbar_inst/*" \
    "*dma_iommu_inst/m2s_bytes_remaining_q_reg*"]

# IOMMU core includes the lookup pipeline, software page table, TLB,
# permission/range/fault logic registers, counters, and nested pseudo-LRU.
set iommu_patterns [list "*dma_iommu_inst/iommu_inst/*"]

# CPU-side MMU is a distinct block from the DMA-side IOMMU.  Report it
# separately so "MMU Fmax" cannot be confused with the IOMMU result.
set cpu_mmu_patterns [list "*cpu_mmu_inst/*"]

set dma_regs [collect_group_registers $dma_patterns]
set iommu_regs [collect_group_registers $iommu_patterns]
set cpu_mmu_regs [collect_group_registers $cpu_mmu_patterns]

set summary_path [file join $report_dir "dma_iommu_separate_fmax.log"]
set fd [open $summary_path w]
puts $fd "SEPARATE DMA AND IOMMU FMAX REPORT"
puts $fd "Design: unified PicoRV32 + DMA/IOMMU SoC"
puts $fd "Device: [get_property PART [current_project]]"
puts $fd "Important: these are post-route internal-path estimates in the full SoC physical context."
puts $fd "They are not behavioral-simulation throughput measurements."
puts $fd "FMAX FORMULA: Tcritical(ns)=Tconstraint(ns)-Slack(ns); Fmax(MHz)=1000/Tcritical(ns)."

set system_path [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
set system_slack_ns [get_property SLACK $system_path]
set system_critical_period_ns [expr {$clock_period_ns-$system_slack_ns}]
set system_fmax_mhz [expr {1000.0/$system_critical_period_ns}]
set system_startpoint [safe_path_property $system_path STARTPOINT_PIN "not available"]
set system_endpoint [safe_path_property $system_path ENDPOINT_PIN "not available"]
puts $fd "------------------------------------------------------------"
puts $fd "CORE: WHOLE SYSTEM"
puts $fd "Scope: PicoRV32 + CPU MMU + DMA + IOMMU + AXI + UART + RAM controller"
puts $fd [format "Reference clock constraint : %.3f ns (%.3f MHz)" \
    $clock_period_ns [expr {1000.0/$clock_period_ns}]]
puts $fd [format "Worst system slack         : %.3f ns" $system_slack_ns]
puts $fd [format "Equivalent critical period : %.3f ns" $system_critical_period_ns]
puts $fd [format "Estimated system Fmax      : %.3f MHz" $system_fmax_mhz]
puts $fd [format "Substitution Tcritical     : %.3f - %.3f = %.3f ns" \
    $clock_period_ns $system_slack_ns $system_critical_period_ns]
puts $fd [format "Substitution Fmax          : 1000 / %.3f = %.3f MHz" \
    $system_critical_period_ns $system_fmax_mhz]
puts $fd "Startpoint                 : $system_startpoint"
puts $fd "Endpoint                   : $system_endpoint"

write_group_result $fd "DMA CORE" \
    "scheduler + axi_cdma + axi_dma_rd + axi_dma_wr + internal axi_crossbar" \
    $dma_regs $clock_period_ns \
    [file join $report_dir "dma_core_internal_timing.rpt"]

write_group_result $fd "IOMMU CORE" \
    "dma_iommu_tlb including Page Table, TLB and pseudo-LRU" \
    $iommu_regs $clock_period_ns \
    [file join $report_dir "iommu_core_internal_timing.rpt"]

write_group_result $fd "CPU MMU CORE" \
    "picorv32_cpu_mmu used on the PicoRV32 memory path" \
    $cpu_mmu_regs $clock_period_ns \
    [file join $report_dir "cpu_mmu_core_internal_timing.rpt"]

puts $fd "------------------------------------------------------------"
puts $fd "END OF SEPARATE FMAX REPORT"
close $fd

# Keep the compact whole-system report synchronized without rerunning
# synthesis or implementation.  All values come from the open routed DCP.
set unified_fmax_path [file join $report_dir "unified_fmax.txt"]
set unified_fd [open $unified_fmax_path w]
puts $unified_fd "UNIFIED PICORV32 + CPU-MMU + DMA/IOMMU + AXI FMAX REPORT"
puts $unified_fd "Formula: Tcritical(ns)=Tconstraint(ns)-WNS(ns)"
puts $unified_fd "Formula: Fmax(MHz)=1000/Tcritical(ns)"
puts $unified_fd [format "Clock constraint: %.3f ns (%.3f MHz)" \
    $clock_period_ns [expr {1000.0/$clock_period_ns}]]
puts $unified_fd [format "WNS: %.3f ns" $system_slack_ns]
puts $unified_fd [format "Substitution: Tcritical=%.3f-(%.3f)=%.3f ns" \
    $clock_period_ns $system_slack_ns $system_critical_period_ns]
puts $unified_fd [format "Substitution: Fmax=1000/%.3f=%.3f MHz" \
    $system_critical_period_ns $system_fmax_mhz]
close $unified_fd

# Fmax belongs to the routed static netlist, not to a traffic pattern.  Emit a
# D01-D09 mapping explicitly so the throughput matrix cannot be misread as
# nine independently synthesized clocks.
set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
set system_slack_ns [get_property SLACK $setup_path]
set system_fmax_mhz [expr {1000.0 / ($clock_period_ns - $system_slack_ns)}]
set dma_path [get_timing_paths -quiet -from $dma_regs -to $dma_regs \
    -delay_type max -max_paths 1 -nworst 1]
set dma_slack_ns [get_property SLACK $dma_path]
set dma_fmax_mhz [expr {1000.0 / ($clock_period_ns - $dma_slack_ns)}]
set iommu_path [get_timing_paths -quiet -from $iommu_regs -to $iommu_regs \
    -delay_type max -max_paths 1 -nworst 1]
set iommu_slack_ns [get_property SLACK $iommu_path]
set iommu_fmax_mhz [expr {1000.0 / ($clock_period_ns - $iommu_slack_ns)}]

set matrix_fmax_path [file join $report_dir "dma_9case_fmax.log"]
set matrix_fd [open $matrix_fmax_path w]
puts $matrix_fd "D01-D09 POST-ROUTE FMAX MAPPING"
puts $matrix_fd "Device: [get_property PART [current_project]]"
puts $matrix_fd "Fmax is static for one implementation; traffic direction/mode changes latency and throughput, not the routed critical path."
puts $matrix_fd "Formula: Tcritical(ns)=Tconstraint(ns)-Slack(ns); Fmax(MHz)=1000/Tcritical(ns)."
puts $matrix_fd [format "System substitution: Tcritical=%.3f-(%.3f)=%.3f ns; Fmax=1000/%.3f=%.3f MHz" \
    $clock_period_ns $system_slack_ns \
    [expr {$clock_period_ns-$system_slack_ns}] \
    [expr {$clock_period_ns-$system_slack_ns}] $system_fmax_mhz]
puts $matrix_fd [format "System Fmax=%.3f MHz | DMA-core Fmax=%.3f MHz | IOMMU-core Fmax=%.3f MHz" \
    $system_fmax_mhz $dma_fmax_mhz $iommu_fmax_mhz]
puts $matrix_fd "------------------------------------------------------------"
puts $matrix_fd "ID  Direction  Mode            System MHz  DMA MHz  IOMMU MHz"
foreach row {
    {D01 M2M BURST}
    {D02 M2M CYCLE-STEALING}
    {D03 M2M TRANSPARENT}
    {D04 S2M BURST}
    {D05 S2M CYCLE-STEALING}
    {D06 S2M TRANSPARENT}
    {D07 M2S BURST}
    {D08 M2S CYCLE-STEALING}
    {D09 M2S TRANSPARENT}
} {
    lassign $row id direction mode
    puts $matrix_fd [format "%-3s %-10s %-15s %10.3f %8.3f %10.3f" \
        $id $direction $mode $system_fmax_mhz $dma_fmax_mhz $iommu_fmax_mhz]
}
puts $matrix_fd "------------------------------------------------------------"
puts $matrix_fd "Use dma_throughput.log for per-case cycles and MB/s."
close $matrix_fd

puts "Created $summary_path"
puts "Created [file join $report_dir dma_core_internal_timing.rpt]"
puts "Created [file join $report_dir iommu_core_internal_timing.rpt]"
puts "Created [file join $report_dir cpu_mmu_core_internal_timing.rpt]"
puts "Created $unified_fmax_path"
puts "Created $matrix_fmax_path"
