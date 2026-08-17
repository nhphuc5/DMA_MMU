# PicoRV32 firmware

For a beginner-friendly explanation of the firmware, Markdown documentation,
toolchain and automated Makefile flow, read [`FIRMWARE.md`](FIRMWARE.md).

`src/soc_demo.cpp` is the freestanding C++17/RV32I program executed by
PicoRV32. It uses no operating system or C++ runtime library. A two-instruction
inline-Assembly reset stub only establishes the stack; all MMU programming,
DMA commands, policies, comparisons, and PASS/FAIL tests are C++ code. It uses
AXI4-Lite register writes to program the DMA/IOMMU IP and executes the complete
three-directions by three-modes matrix:

| ID | Direction | Mode | Real data used by the regression |
|---|---|---|---|
| D01 | Memory -> Memory | Burst | RAM `0x4000` -> `0x5000` |
| D02 | Memory -> Memory | Cycle-Stealing | RAM `0x4020` -> `0x5020` |
| D03 | Memory -> Memory | Transparent | RAM `0x4040` -> `0x5040` |
| D04 | UART -> Memory | Burst | UART `A0..A7` -> RAM `0x6000` |
| D05 | UART -> Memory | Cycle-Stealing | UART `B0..B7` -> RAM `0x6020` |
| D06 | UART -> Memory | Transparent | UART `C0..C7` -> RAM `0x6040` |
| D07 | Memory -> UART | Burst | RAM bytes `10..17` -> UART |
| D08 | Memory -> UART | Cycle-Stealing | RAM bytes `20..27` -> UART |
| D09 | Memory -> UART | Transparent | RAM bytes `30..37` -> UART |

Before starting the matrix, the firmware programs identity-mapped IOMMU page
table entries for pages `0x4000` to `0x7000`.  It polls the real DMA status,
rejects any IOMMU/DMA fault, compares every memory destination, and emits `P`
only after all nine commands complete successfully.

CPU writes of `START` and descriptor `PUSH` are the authorization for D01-D09
and Q01, so those commands execute without a redundant request/grant round
trip.  After Q01, firmware runs P01: it enables UART autonomous request mode,
the testbench sends physical UART bytes `E0..E7` without CPU `START`, hardware
raises a request IRQ, and PicoRV32 reads the captured request before granting
it.  RAM `0x6060..0x6067` is compared with the actual UART input.  A denial
would stop before IOMMU/AXI activity with fault `0x70`.

Before the DMA test matrix, firmware also programs the independent CPU-side
MMU at `0x3000_0000`.  It creates executable/readable identity mappings for
code, writable identity mappings for stack and DMA buffers, and a deliberately
non-identity mapping `VA 0x00008000 -> PA 0x00003000`.  A write/read through
that VA and the physical AXI RAM contents are self-checked before marker `M` is
emitted.  The CPU MMU and DMA IOMMU remain separate protection domains.

The firmware then submits Q01: eight independent M2M descriptors (IDs
`0x40..0x47`) to the hardware FIFO before allowing the queue to run.  It waits
for eight real completions, verifies all eight scattered RAM destinations,
checks FIFO completion order/byte counts, and emits UART marker `Q`.  Marker
`P` is emitted only after D01-D09, Q01, and autonomous peripheral test P01 pass.

UART markers `S`, `1..9`, `A/B/C`, `X/Y/Z`, `Q`, `R`, `V`, `P`, and `F` coordinate the
firmware with the external self-checker.  They are phase/result handshakes,
not replacement data: `tb_dma_mmu_picorv32_soc.sv` still drives real 8N1 RX
frames and observes the real UART TX byte path.

Run `build_firmware.cmd`; it invokes Vitis GNU Make, which reads `Makefile` and
uses `riscv32-xilinx-elf-g++`. The build explicitly targets `-march=rv32i` and
`-mabi=ilp32`, then regenerates `build/soc_demo.elf`, `build/soc_demo.bin`, and
`build/soc_demo.hex`. Target `verify` checks that the ELF is 32-bit RISC-V and
RV32I before the HEX image is used. Vivado `$readmemh` loads that HEX file into
the 64-KiB AXI RAM, and PicoRV32 fetches and executes it from address zero.
