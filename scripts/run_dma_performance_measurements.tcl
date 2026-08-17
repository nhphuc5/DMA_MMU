# One command to refresh the DMA throughput log and the separate DMA/IOMMU
# post-route Fmax reports in the unified Vivado project.
set script_dir [file dirname [file normalize [info script]]]

source [file join $script_dir "run_unified_simulation.tcl"]
catch {close_sim}
source [file join $script_dir "report_dma_iommu_fmax.tcl"]

puts "DMA performance reports are available under Project_Vivado/reports."
