# PicoRV32 + DMA + IOMMU + AXI SoC

This directory is organized by hardware function.  The canonical Vivado
project is generated from the files below; generated Vivado data is kept under
`build/vivado` and is not mixed with the RTL sources.

## Directory layout

```text
Project_Vivado/
|-- src/
|   |-- DMA/       DMA control, scheduler, and three transfer engines
|   |-- IOMMU/     DMA-side address translation, permissions, TLB, pseudo-LRU
|   |-- PicoRV32/  PicoRV32 core, CPU-side MMU, and AXI4-Lite address router
|   |-- AXI/       Shared AXI infrastructure, arbiters, crossbar, and AXI RAM
|   |-- UART/      UART engine and AXI4-Lite/AXI-Stream wrapper
|   |-- Systolic/  4x4 signed INT8 matrix accelerator and AXI4-Lite wrapper
|   `-- SoC/       DMA/IOMMU IP integration and complete SoC top
|-- firmware/
|   |-- src/       RISC-V Assembly source
|   |-- include/   SoC address/register definitions
|   |-- tools/     BIN-to-HEX conversion tool
|   `-- build/     ELF, BIN, and HEX generated firmware files
|-- testbench/     Self-checking DMA/IOMMU, CPU/SoC, and unified tests
|-- testdata/      Deterministic byte-exact UART transfer input files
|-- constraints/   Active SoC timing constraints
|-- scripts/       Canonical Vivado creation, simulation, and report scripts
|-- reports/       Simulation, throughput, timing, Fmax, and utilization logs
|-- docs/          Architecture documentation and final report
|-- archive/       Legacy RTL/tests/constraints not used by the unified project
`-- build/vivado/  Generated Vivado project and run products
```

## Canonical entry points

- Synthesis top: `dma_mmu_picorv32_soc`
- Simulation top: `tb_dma_iommu_picorv32_unified`
- Vivado project: `build/vivado/unified/DMA_IOMMU_PicoRV32_Unified.xpr`
- Firmware image: `firmware/build/soc_demo.hex`

## Optional 4x4 systolic matrix accelerator

The VC707 systolic variant preserves the complete PicoRV32, DMA/IOMMU, AXI,
UART, CPU-MMU and memory system, then adds a 4x4 output-stationary systolic
array at AXI4-Lite base address `0x4000_0000`.  It multiplies signed INT8
matrices and returns a signed INT32 result matrix.  PicoRV32 firmware writes
both input matrices, starts the hardware, reads all 16 results and prints a
real self-checking PASS/FAIL result over UART.

- Open/build helper: `OPEN_VC707_SYSTOLIC_PROJECT.cmd`
- Full bitstream build: `BUILD_VC707_SYSTOLIC_BITSTREAM.cmd`
- Dedicated project: `build/vivado/vc707_systolic/DMA_IOMMU_PicoRV32_VC707_Systolic.xpr`
- Architecture and register map: `docs/SYSTOLIC_ARRAY_GUIDE.md`
- End-to-end result: `reports/systolic_soc_test.log`

## Complete zero-DSP VC707 physical DDR3 SoC

The physical-board target retains a 256-KiB AXI boot/scratch RAM and connects the
SoC's `0x8000_0000`--`0xBFFF_FFFF` aperture to the VC707 1-GiB x64 DDR3
SODIMM.  It uses a reproducibly generated Xilinx MIG 7 Series PHY/controller,
an AXI clock-domain converter, and a 32-to-512-bit AXI data-width converter.
The integrated firmware waits for real MIG calibration and then implements a
run-time multi-image path through UART, all three DMA directions, DMA-side
IOMMU, physical DDR3 and the 4x4 INT8 systolic accelerator.

- Recommended full-SoC build: `BUILD_VC707_UNIFIED_DDR3_BITSTREAM.cmd`
- Generated bitstream: `bitstream/DMA_IOMMU_PicoRV32_VC707_Unified_DDR3.bit`
- Integrated RV32I firmware: `firmware/prebuilt/vc707_unified/soc_uart_image_batch.hex`
- End-to-end deployment guide: `docs/VC707_UNIFIED_SOC_DEPLOYMENT.md`
- UART image protocol/host tool: `docs/UART_MULTI_IMAGE_BATCH.md`
- Verified reports and logs: `reports/vc707_unified_ddr3/`

The standalone DDR acceptance image remains available for board bring-up:

- One-command Windows build: `BUILD_VC707_DDR3_BITSTREAM.cmd`
- Physical top: `src/SoC/dma_mmu_picorv32_vc707_ddr3_top.sv`
- MIG configuration and all DDR pin assignments: `ip/vc707_mig_7series/mig.prj`
- Prebuilt RV32I self-test: `firmware/prebuilt/vc707_ddr3/soc_ddr3_test.hex`
- Clone/build/program/UART procedure: `docs/VC707_DDR3_DEPLOYMENT.md`
- Implementation evidence: `reports/vc707_ddr3/`

The clean Vivado 2025.1 route for `xc7vx485tffg1761-2` closes the 150-MHz SoC
clock at WNS `+0.059 ns` and WHS `+0.054 ns`, with 0 DRC errors. The complete
SoC, including the LUT-based systolic accelerator and MIG/DDR path, uses
**zero DSP48E1 blocks**. See the raw timing/utilization reports rather than
assuming these values for a different Vivado version or implementation seed.

## Two independent address-translation domains

The SoC deliberately contains two different translation blocks.  The new
`picorv32_cpu_mmu` translates PicoRV32 instruction/data virtual addresses and
checks read/write/execute permissions.  The existing `dma_iommu_tlb` translates
DMA I/O virtual addresses and protects RAM from DMA masters.  Neither block is
silently shared or bypassed for the other master.  See `docs/CPU_SIDE_MMU.md`.

## Rebuild firmware

Run `firmware/build_firmware.cmd`. It uses Vitis 2025.1's dedicated
`riscv32-xilinx-elf-g++` compiler with `-march=rv32i -mabi=ilp32`, verifies an
ELF32/RISC-V output, and only replaces the HEX image after every build step
succeeds. The functional firmware is freestanding C++ in
`firmware/src/soc_demo.cpp`.
The firmware programs the IOMMU page table and runs all nine combinations of
the three directions (memory-to-memory, UART-to-memory, memory-to-UART) and the
three modes (Burst, Cycle-Stealing, Transparent).  Every combination uses an
independent address and data pattern.

The firmware polls real DMA/IOMMU status and checks memory destinations.  The
SoC testbench independently drives physical UART RX frames, observes physical
UART TX bytes, compares RAM, and writes every input/output value to
`reports/picorv32_soc_test.log`.  A final PASS is possible only after D01-D09
have all matched.

After D01-D09, the firmware also pauses and fills an eight-entry descriptor
FIFO, then resumes it so the DMA copies eight non-contiguous memory regions
without CPU polling between jobs.  Descriptor order, copied data, completion
IDs, byte counts, full/overflow handling, per-descriptor IRQ, and stop-on-IOMMU
fault are self-checked.  See `docs/DESCRIPTOR_QUEUE_SCATTER_GATHER.md`.

The integrated SoC uses hybrid DMA authorization.  CPU `START` and descriptor
`PUSH` already express software approval and run immediately.  An autonomous
UART RX request is captured before IOMMU/AXI activity, raises IRQ, and waits
for PicoRV32 to write GRANT or DENY.  After a grant, the IOMMU independently
translates the IOVA and checks page range and permissions.  See
`docs/DMA_CPU_ACCESS_CONTROL.md`.

## Recreate the Vivado project

From the Vivado Tcl Console:

```tcl
source C:/rtl/rtl/Project_Vivado/scripts/create_unified_project.tcl
```

Use `scripts/run_unified_simulation.tcl` for verification and
`scripts/run_unified_implementation.tcl` for post-route timing/utilization.

## Verification coverage and result files

The DMA/IOMMU component testbench executes all nine combinations of three
directions and three transfer modes.  It checks transferred RAM/stream data,
not pre-written PASS strings.  The same regression injects unmapped-page,
permission, 4 KiB range, AXI READY/backpressure, AXI SLVERR/DECERR, invalid
length/alignment, busy-command, and mid-transfer reset conditions.

- `reports/dma_throughput.log`: cycles and measured MB/s for D01-D09.
- `reports/dma_edge_cases.log`: self-checking results for D01-D09 and E01-E20.
- `reports/dma_9case_fmax.log`: post-route system/DMA/IOMMU Fmax.
- `reports/cpu_mmu_test.log`: CPU-MMU translation, permission and fault tests.
- `reports/unified_verification.log`: one-run result for CPU MMU, PicoRV32 SoC,
  DMA/IOMMU, AXI and UART.
- `docs/DESCRIPTOR_QUEUE_SCATTER_GATHER.md`: queue register map and operation.
- `docs/DMA_CPU_ACCESS_CONTROL.md`: hybrid authorization: CPU `START/PUSH`
  runs directly, while autonomous UART requests use IRQ plus CPU GRANT/DENY.
- `docs/CPU_SIDE_MMU.md`: CPU virtual-memory translation, TLB, permissions,
  register map, and its separation from the DMA-side IOMMU.
- `scripts/run_axi_edge_regression.tcl`: reproducible isolated XSim regression.
- `testdata/uart_input_50k.txt`: exact 51,200-byte UART stress-test payload.
- `scripts/run_uart_file_transfer.tcl`: runs the physical UART-to-RAM test.
- `reports/uart_file_to_memory_50k.log`: byte counts, checksums, AXI bursts,
  latency, throughput, mismatches, and final PASS/FAIL for the 50 KiB file.
