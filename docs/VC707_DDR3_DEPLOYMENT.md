# VC707 physical DDR3 deployment

## What is included

This target is complete at the RTL/IP/constraint/firmware level for the
standard VC707 board and its 1-GiB x64 Micron DDR3 SODIMM.  `axi_ram` remains
the 256-KiB boot/scratch memory at `0x0000_0000`; DDR3 occupies
`0x8000_0000`--`0xBFFF_FFFF`.

The physical path is:

```text
PicoRV32 + CPU MMU + DMA/IOMMU + UART + systolic accelerator
        | 32-bit AXI, 150 MHz
        v
AXI clock converter (150 -> 200 MHz)
        | 32-bit AXI, 200 MHz
        v
AXI width converter (32 -> 512 bits)
        | 512-bit AXI, 200 MHz
        v
Xilinx MIG 7 Series controller + x64 PHY + calibration/training
        |
        v
VC707 DDR3 SODIMM pins
```

The source files that demonstrate the physical implementation are:

- `ip/vc707_mig_7series/mig.prj`: exact `xc7vx485tffg1761-2`, Micron
  `MT8JTF12864HZ-1G6`, x64, 1-GiB configuration and every DDR3 pin.
- `scripts/generate_vc707_mig_ip.tcl`: regenerates official Xilinx
  `mig_7series`, AXI clock-converter, and AXI width-converter IP.
- `src/SoC/dma_mmu_picorv32_vc707_ddr3_top.sv`: board top integrating the
  complete SoC, converters, MIG, clocks, reset synchronizers and DDR pins.
- `constraints/dma_mmu_picorv32_vc707_ddr3.xdc`: reset, UART and LEDs.  The
  generated MIG XDC owns the system-clock and DDR electrical/timing rules.
- `firmware/src/soc_ddr3_test.cpp`: board acceptance test.

Generated MIG HDL is deliberately not committed.  Vivado recreates it from
the tracked `.prj`, which avoids tool-version-specific absolute paths and IP
cache files.

## Requirements on the destination PC

1. A VC707 with its standard DDR3 SODIMM installed, JTAG connection and
   USB-UART connection.
2. Vivado 2025.1 with Virtex-7 device support.  The scripts select the exact
   part `xc7vx485tffg1761-2`; VC707 board files are optional.
3. A valid local Vivado/implementation license for that part.  Do not copy or
   commit another user's `.lic` file.
4. About 8 GB of free RAM and sufficient disk space for generated IP/project
   products.
5. A checkout path without parentheses is recommended because some Vivado IP
   and XDC commands reject such project paths.

No RISC-V compiler is required for the normal build: the verified firmware
HEX is committed under `firmware/prebuilt/vc707_ddr3/`.  Vitis is needed only
when modifying and rebuilding the firmware.

## Build the bitstream

Clone the repository, open a normal Command Prompt in its root, then run:

```bat
BUILD_VC707_DDR3_BITSTREAM.cmd
```

If Vivado is installed in a different location, set the executable first:

```bat
set VIVADO=C:\Xilinx\Vivado\2025.1\bin\vivado.bat
BUILD_VC707_DDR3_BITSTREAM.cmd
```

The script generates all IP, synthesizes and implements the complete top,
requires non-negative post-route WNS, runs DRC, writes reports, and creates:

```text
bitstream/DMA_IOMMU_PicoRV32_VC707_DDR3.bit
reports/vc707_ddr3/vc707_ddr3_build_summary.txt
reports/vc707_ddr3/vc707_ddr3_timing.rpt
reports/vc707_ddr3/vc707_ddr3_drc.rpt
reports/vc707_ddr3/vc707_ddr3_utilization_hierarchical.rpt
```

The build is successful only when the console ends with
`VC707 DDR3 BITSTREAM PASSED`.

## Program and run the board test

1. Connect and power the VC707.
2. Open Vivado Hardware Manager, open the target, select the
   `xc7vx485t_0` device and program the generated `.bit` file.
3. Open the VC707 USB-UART port at **115200 baud, 8 data bits, no parity,
   1 stop bit, no flow control**.
4. Press CPU RESET once after programming if output has already scrolled.

LED meanings:

- LED0: MIG calibration completed.
- LED1: PicoRV32 trap.
- LED2: DMA interrupt.
- LED3: MIG and SoC clock managers locked.

Expected successful UART transcript:

```text
VC707 DDR3 SELF-TEST START
Waiting for MIG calibration...
PASS MIG calibration
PASS 32-bit data bus walking ones/zeros
PASS byte/halfword narrow access and WSTRB
PASS DDR address lines across 1-GiB aperture
PASS 64-KiB checkerboard
PASS 64-KiB deterministic pseudo-random pattern
PASS DMA/IOMMU BRAM->DDR3->BRAM
ALL VC707 DDR3 TESTS PASSED
```

Any `FAIL` line includes the failing stage, address, expected value and actual
value.  LED0 staying off indicates that the test has not passed MIG's real
power-up calibration/training.

## Evidence and validation boundary

The committed controller simulation logs cover AXI bursts, narrow accesses,
WSTRB, backpressure, response errors, WLAST, reset, row hit/conflict and
refresh.  These tests use the repository's behavioral DFI model:

- `reports/ddr3_controller/xsim_controller_regression.log`: 278/278 checks.
- `reports/ddr3_controller/xsim_bram_ddr_integration.log`: 10/10 checks.
- `reports/ddr3_controller/xsim_external_mig_bridge.log`: 15/15 checks for retained AXI RAM,
  address rebasing, ID/WSTRB/response forwarding, status and backpressure.
- `reports/unified_verification.log`: complete CPU/MMU/DMA/IOMMU/AXI/UART
  regression.

Post-route Vivado reports prove that the official MIG controller/PHY and
physical DDR I/O primitives are present, all pin/timing constraints were
accepted, DRC passed, and the bitstream was generated.  Only the UART
transcript from an actual VC707 can prove board-specific signal integrity and
successful runtime calibration.  A PC without a connected VC707 cannot
truthfully produce that final physical-memory PASS result.

The current recommended unified Vivado 2025.1 clean build for
`xc7vx485tffg1761-2` completed with setup WNS `+0.059 ns`, hold WHS
`+0.054 ns`, zero timing failures, zero DRC errors/critical warnings and all
AXI CDC bus-skew constraints met. See `reports/vc707_unified_ddr3/`.

The complete current SoC uses **0 DSP**: the systolic INT8 multipliers are
implemented in LUT fabric, and MIG plus both AXI converters also use 0 DSP.

## Rebuild the firmware after editing it

With Vitis 2025.1 installed, run:

```bat
firmware\build_vc707_ddr3_firmware.cmd
```

The helper verifies ELF32/RISC-V/RV32I and updates the tracked prebuilt HEX.
Run the full bitstream build again afterward so the new image is initialized
into `axi_ram`.
