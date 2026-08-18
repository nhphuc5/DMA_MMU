# VC707 unified SoC evidence index

Target: `xc7vx485tffg1761-2`, Vivado 2025.1, 150-MHz SoC clock.

| Evidence | Result |
|---|---|
| `vc707_ddr3_build_summary.txt` | Synthesis and bitstream complete, WNS +0.059 ns, WHS +0.054 ns, DRC 0, DSP 0 |
| `vc707_ddr3_timing.rpt` | All user timing constraints met |
| `vc707_ddr3_utilization.rpt` | 39,104 LUT, 60,366 registers, 64 BRAM tiles, 0 DSP |
| `vc707_ddr3_drc.rpt` | Raw routed DRC report |
| `vc707_ddr3_bus_skew.rpt` | Raw AXI clock-domain bus-skew report |
| `vc707_ddr3_synthesis.log` | Complete synthesis transcript |
| `vc707_ddr3_implementation.log` | Complete place/route/bitstream transcript |
| `firmware_build.log` | ELF32 RISC-V RV32I firmware build and ISA verification |
| `xsim_ddr3_controller.log` | 278/278 controller checks PASS |
| `xsim_unified_regression.log` | CPU/MMU/DMA/IOMMU/UART and all 9 direction/mode cases PASS |
| `xsim_uart_dma_ddr_systolic.log` | Multi-image UART/DMA/DDR/Systolic pipeline PASS |
| `uart_image_batch_soc_test.log` | Frame CRC/data checks and DMA performance counters |
| `vc707_unified_fmax.txt` | Slack-equivalent Fmax estimate 151.332 MHz |

Artifact SHA-256 values for this run:

```text
firmware/prebuilt/vc707_unified/soc_uart_image_batch.hex
8A07D17501AB062393827919CEE932A79A23F2E45010C82976F20B0C2F4FA158

bitstream/DMA_IOMMU_PicoRV32_VC707_Unified_DDR3.bit
16102F287A3456A78E565366DCC4AC0E6A3612C8FDA46DBEA1C893370C248436
```

Simulation and implementation cannot replace a real-board run. Successful
MIG calibration and UART CRC/PASS output on the particular VC707 remain the
final electrical/hardware acceptance step.
