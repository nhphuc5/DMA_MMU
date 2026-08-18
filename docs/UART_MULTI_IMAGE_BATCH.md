# VC707 run-time multi-image DMA pipeline

## Purpose

This target loads image data into the **physical VC707 DDR3 SODIMM at run
time**. The images are not compiled into firmware.
PicoRV32 parses only packet headers; image payload bytes are transferred by
DMA and protected by the DMA-side IOMMU.

## Capacity and image format

- Any number of input files; four frames are resident per DDR3 batch.
- The host automatically continues with the next batch after `DONE`, without
  rebuilding the bitstream or resetting the board.
- Each padded frame can occupy up to 64 MiB.
- PC input: PNG, JPG/JPEG, BMP, TIFF.
- Hardware format: unsigned grayscale pixels, padded on the right/bottom to a
  multiple of 4, then centered as signed INT8 and packed in 4x4 tile order.
- The application does not scale an image to 64x64.  Cropping after reception
  restores the original width and height.

## Real data path

1. The host sends `UPL1` metadata and waits for `RDY1`.
2. UART RX supplies AXI-Stream bytes to DMA S2M.
3. DMA S2M writes the selected input slot through AXI4-Full.
4. Firmware checks CRC32 by reading that DDR3 slot.
5. DMA M2M copies the slot to the shared work buffer.
6. DMA M2S streams each 4x4 tile and the identity matrix into the systolic
   accelerator.
7. DMA S2M stores each signed INT32 result tile in the 256-KiB AXI scratch
   RAM. PicoRV32 saturates it to 0..255 and assembles the output in DDR3.
8. DMA M2S streams output DDR3 to UART TX.
9. The host verifies CRC32 and writes PNG, BIN, HEX and TXT artifacts.

The firmware programs IOMMU read/write permissions before every DMA phase.
An unmapped or incorrectly permitted address therefore produces a DMA fault
instead of silently accessing RAM.

## Memory map

| Address range | Purpose |
|---|---|
| `0x0000_0000-0x0003_FFFF` | 256-KiB `axi_ram`: firmware, stack, scratch and identity matrix |
| `0x8000_0000-0x8FFF_FFFF` | Four 64-MiB DDR3 input slots |
| `0x9000_0000-0x9FFF_FFFF` | Four 64-MiB DDR3 M2M work slots |
| `0xA000_0000-0xAFFF_FFFF` | Four 64-MiB DDR3 output slots |
| `0xB000_0000-0xBFFF_FFFF` | Reserved DDR3 aperture |

## Verification scope

`tb_soc_uart_image_batch.sv` sends two frames over the physical UART RX model,
then checks protocol tags, CRCs, returned pixels and actual DDR-model words. PASS is
printed only after the data has traversed S2M, M2M and M2S.  The independent
DMA edge regression additionally tests all nine direction/mode combinations:
M2M, S2M and M2S crossed with Burst, Cycle-Stealing and Transparent.

## Build and simulate

Run the tracked self-checking integrated simulation from a command prompt:

```bat
vivado -mode batch -source scripts\run_vc707_unified_batch_simulation.tcl
```

The committed evidence is under `reports\vc707_unified_ddr3\`.

## Program VC707 and transfer images

1. Place one or more images in `firmware\images\uart_batch_input`.
2. Build a bitstream with `BUILD_VC707_UNIFIED_DDR3_BITSTREAM.cmd`.
3. In Vivado Hardware Manager, program:
   `bitstream\DMA_IOMMU_PicoRV32_VC707_Unified_DDR3.bit`.
4. Close every serial terminal using the board COM port.
5. Run `python firmware/tools/uart_multi_image_app.py COM5 --baud 921600`.
6. If the app is waiting, press and release VC707 `CPU_RESET` once.

Each output is stored below `reports\uart_batch_output\<timestamp>`:

- `.png`: directly viewable reconstructed image.
- `.bin`: exact row-major grayscale bytes for another application.
- `.hex`: one hexadecimal byte per line for inspection/import.
- `.txt`: frame dimensions, byte count and CRC32.

Vivado simulation does not require a paid device synthesis license.  Creating
the VC707 bitstream requires a valid Vivado license covering `xc7vx485t`.

## DMA modes

The image pipeline is identical in all three tests.  Only the DMA scheduling
mode encoded in every real descriptor changes.  Therefore the returned image
and CRC must remain identical, while the transfer timing is allowed to change.

The RTL implements Burst (`0`), Cycle-Stealing (`1`) and Transparent (`2`).
The tracked board image selects Burst for maximum UART/image throughput. The
unified regression exercises all nine direction/mode combinations. To build a
different board image, rebuild the firmware with
`vc707-uart-image-batch-cycle` or `vc707-uart-image-batch-transparent`, copy
the resulting HEX into the prebuilt location, and rerun the bitstream build.

### Cycle-Stealing board scenario

For each image, UART RX supplies the real payload to DMA.  Each DMA engine
performs one transfer unit and then releases its scheduling opportunity before
continuing.  The test covers UART-to-RAM, RAM-to-RAM, RAM-to-systolic,
systolic-to-RAM and RAM-to-UART.  PASS requires the returned output length and
CRC32 to match the values produced from the bytes actually received by the PC.

### Transparent board scenario

The same end-to-end image path is used, but a DMA transfer unit is issued only
when `cpu_bus_idle` is asserted.  CPU accesses pause DMA progress; idle gaps let
DMA continue.  This normally has the longest and most variable completion time.
PASS still requires the returned image and CRC32 to be identical to the Burst
reference.

Because the firmware HEX is initialized into FPGA BRAM, changing the selected
mode requires programming the matching `.bit` file.  It is not enough to run a
different host `--scenario` option with the old bitstream.

The same timestamped directory contains three hardware performance logs for
the DMA endpoints, AXI4-Full bus and complete VC707 system. See
`docs/VC707_DMA_PERFORMANCE_LOGS.md` for formulas, file names and exact board
commands.
