# Unified PicoRV32 + DMA/IOMMU Vivado project

Use only this project:

`C:/rtl/rtl/Project_Vivado/vivado_unified_project/DMA_IOMMU_PicoRV32_Unified.xpr`

- Synthesis/implementation top: `dma_mmu_picorv32_soc`
- Simulation top: `tb_dma_iommu_picorv32_unified`
- Clock constraint: 140 MHz (`7.143 ns`)
- CPU/SoC and full DMA/IOMMU AXI verification run together.

One unified simulation writes:

- `reports/unified_verification.log`: overall result
- `reports/picorv32_soc_test.log`: PicoRV32 firmware, UART and per-word CPU/DMA input-output comparison
- `reports/dma_mmu_axi_test.log`: per-word input-output comparison for all three transfers, three DMA modes, AXI and IOMMU/TLB result
- `reports/dma_throughput.log`: DMA command latency, DMA source/destination endpoint speed, AXI4 read/write bus speed and utilization for all three transfer modes
- `reports/dma_iommu_separate_fmax.log`: post-route Fmax estimates scoped separately to the DMA core and IOMMU core
- `reports/dma_core_internal_timing.rpt`: detailed DMA-only internal timing paths
- `reports/iommu_core_internal_timing.rpt`: detailed IOMMU-only internal timing paths

Vivado Tcl commands:

```tcl
source C:/rtl/rtl/Project_Vivado/scripts/run_unified_simulation.tcl
source C:/rtl/rtl/Project_Vivado/scripts/run_unified_implementation.tcl
source C:/rtl/rtl/Project_Vivado/scripts/run_dma_performance_measurements.tcl
```

`run_dma_performance_measurements.tcl` is the one-command measurement flow.
It refreshes the simulation throughput report and then reads the current
implemented checkpoint to refresh the separate DMA/IOMMU Fmax reports.

Throughput definitions:

- DMA standalone reference: theoretical raw datapath bandwidth with ideal
  source/destination (`DATA_WIDTH/8` bytes every clock), without AXI address,
  response, arbitration or IOMMU latency.
- DMA + IOMMU + AXI effective speed: payload bytes divided by the complete
  command interval from internal `cfg_start` to `done`.
- AXI full-transaction speed: transferred bytes divided by the complete AXI
  interval (`AR` through last `R`, or `AW` through write response `B`).
- AXI active-beat speed is also printed as an instantaneous diagnostic and
  must not be interpreted as the complete system throughput.
- MB/s values in the behavioral benchmark use the testbench clock of 100 MHz. A 32-bit bus can transfer at most 400 MB/s per direction at this clock.

Fmax definitions:

- DMA core scope: scheduler, `axi_cdma`, `axi_dma_rd`, `axi_dma_wr`, and the internal `axi_crossbar`.
- IOMMU core scope: `dma_iommu_tlb`, software Page Table, TLB, permission/range logic, counters, and `pseudoLRU`.
- Fmax is estimated from post-route internal register-to-register timing paths in the complete SoC physical context.

The testbenches are Simulation Sources only. They do not add LUTs, registers,
I/O ports, or timing paths to the implemented hardware.
