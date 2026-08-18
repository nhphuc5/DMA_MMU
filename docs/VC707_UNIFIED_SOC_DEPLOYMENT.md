# VC707 unified zero-DSP SoC deployment

This is the recommended physical target. It integrates PicoRV32, CPU MMU,
DMA with descriptor queue and all three scheduling modes, DMA IOMMU, retained
256-KiB `axi_ram`, AXI interconnect, UART AXI-Lite/AXI-Stream, LUT-based 4x4
INT8 systolic accelerator, AXI clock/data-width conversion, and the official
Xilinx MIG 7 Series x64 DDR3 controller/PHY.

## Reproducible source provenance

The UART multi-image, DMA performance-counter and batch-systolic work was
ported from `Phongleeeee/DMA_MMU` commit
`682f45d2e86e17fdd5193542a7d3d4f33ddd83f7`. It was adapted to this
repository's independent DDR3/MIG architecture instead of replacing it. The
external clone is intentionally ignored; the required merged RTL, firmware,
host tool and tests are tracked directly in this repository.

The inspected upstream revision does not contain a `LICENSE` file. Before
public redistribution, the repository owner should confirm that they have
permission to publish the ported upstream portions under the intended terms.

## What the destination machine needs

- Windows, a standard VC707 with the x64 DDR3 SODIMM, JTAG and USB-UART.
- Vivado 2025.1 with Virtex-7 device support and a valid implementation
  license for `xc7vx485tffg1761-2`.
- A checkout path without parentheses; Vivado IP subprocesses can reject
  paths containing `(` or `)`.
- No RISC-V compiler for the normal build. The verified RV32I HEX is tracked.
  Vitis is required only when firmware source is changed.

Do not copy a license file into the repository. Install it locally through
Vivado License Manager or the normal Xilinx license environment.

## Build and program

From a normal Command Prompt in the repository root:

```bat
BUILD_VC707_UNIFIED_DDR3_BITSTREAM.cmd
```

If Vivado is not found automatically:

```bat
set VIVADO=C:\Xilinx\Vivado\2025.1\bin\vivado.bat
BUILD_VC707_UNIFIED_DDR3_BITSTREAM.cmd
```

The script regenerates/uses the tracked MIG configuration, synthesizes,
places and routes the full top, rejects negative setup/hold slack, rejects
DRC errors, rejects any DSP48 instance, and creates:

```text
bitstream/DMA_IOMMU_PicoRV32_VC707_Unified_DDR3.bit
reports/vc707_unified_ddr3/vc707_ddr3_build_summary.txt
reports/vc707_unified_ddr3/vc707_ddr3_timing.rpt
reports/vc707_unified_ddr3/vc707_ddr3_utilization.rpt
reports/vc707_unified_ddr3/vc707_ddr3_drc.rpt
```

Program that `.bit` with Vivado Hardware Manager. LED0 indicates MIG
calibration complete. The firmware does not access DDR until the MIG status
reports calibration done; calibration error prints `DERR` on UART.

Install Pillow and pyserial on the host, add images to
`firmware/images/uart_batch_input`, then run:

```bat
python -m pip install pillow pyserial
python firmware\tools\uart_multi_image_app.py COM5 --baud 921600
```

Replace `COM5` with the VC707 UART port. Output PNG/BIN/HEX/TXT and CRC/perf
records are written beneath `reports/uart_batch_output`.

## Verified implementation result

Vivado 2025.1 completed the exact `xc7vx485tffg1761-2` target at a 150-MHz
SoC clock with WNS `+0.059 ns`, WHS `+0.054 ns`, 0 DRC errors and 0 critical
warnings. Resource use after route is 39,104 Slice LUTs (12.88%), 60,366
Slice Registers (9.94%), 64 Block RAM tiles (6.21%) and 0 DSP (0%).
The slack-equivalent Fmax estimate is 151.332 MHz; changing the clock still
requires a new route to certify timing.

The raw evidence is committed in `reports/vc707_unified_ddr3/`. Behavioral
simulation proves protocol/data behavior; implementation reports prove that
the design can become a legal timing-closed bitstream. Only running it on the
actual board can prove that a particular SODIMM, PCB and power-up instance
complete physical DDR calibration and data transfer.

## Verification evidence

- `xsim_ddr3_controller.log`: 278/278 DDR-controller checks PASS.
- `xsim_unified_regression.log`: CPU/MMU/DMA/IOMMU/UART regression PASS,
  including all three DMA directions crossed with all three modes.
- `xsim_uart_dma_ddr_systolic.log`: UART -> DMA S2M -> DDR -> DMA M2M ->
  Systolic -> DMA S2M -> DDR -> DMA M2S -> UART multi-image path PASS.
- `uart_image_batch_soc_test.log`: frame CRC/data and DMA performance detail.
- `vc707_ddr3_build_summary.txt`: timing, DRC, DSP and firmware identity.

The committed bitstream is a convenience artifact. Rebuild it locally before
release so the report, Vivado version, seed and local license provenance are
known to the receiving team.
