# Self-checking verification

## UART 50 KiB file-to-memory regression

`tb_uart_file_to_memory.sv` sends every byte of
`testdata/uart_input_50k.txt` as a physical 8N1 UART frame. The verified path
is UART RX -> AXI4-Stream -> DMA/IOMMU -> AXI4-Full -> AXI RAM. It compares
all 51,200 destination bytes and checks UART overrun, AXI byte counts,
checksums, burst statistics, latency, and throughput.

Generate and run it with:

```powershell
python scripts/generate_uart_50k_testfile.py
```

```tcl
source {D:/DMA_MMU-main(1)/scripts/run_uart_file_transfer.tcl}
```

The human-readable result is `reports/uart_file_to_memory_50k.log`.

- `tb_dma_mmu_axi_top.sv`: component-level regression that drives real RAM,
  AXI4, AXI-Stream, scheduler, and IOMMU handshakes.  It checks all nine DMA
  direction/mode combinations (D01-D09), records cycles/MB/s/burst lengths,
  verifies Burst continuity, Cycle-Stealing bus-release gaps, and Transparent
  CPU-idle waiting.  It also checks E01-E20: page/permission/range faults,
  TLB hit/miss/invalidate/pseudo-LRU, AXI READY stalls and SLVERR/DECERR,
  stream backpressure, boundary lengths/alignment, multi-burst splitting,
  busy-command suppression, and reset during an active transfer.
  Q01 additionally fills all eight descriptor FIFO entries, checks overflow,
  real scattered copies, completion order, pop behavior, and selective IRQ.
  Q02 injects an IOMMU permission fault in the middle of a queue and checks
  stop-on-error plus preservation/flush of the remaining descriptor.
- `tb_dma_mmu_picorv32_soc.sv`: runs the compiled PicoRV32 firmware and checks
  all nine direction/mode combinations end to end.  It drives 32 real 8N1
  bytes into `uart_rx_i`, checks all six UART-to-memory RAM words, checks every
  byte of all three memory-to-UART outputs, and compares all three M2M copies.
  It also verifies the CPU-driven eight-descriptor Q01 by reading all eight
  non-contiguous RAM destinations and the final completion state.  P01 then
  proves the hybrid access policy: UART autonomously supplies `E0..E7`, raises
  one access IRQ, waits for one CPU GRANT, and only then writes two real words
  to RAM; ordinary CPU `START/PUSH` commands issue no duplicate requests.
- `tb_dma_iommu_picorv32_unified.sv`: runs both test environments and passes
  only when both component groups pass.

## Generated verification reports

- `reports/dma_mmu_axi_test.log`: functional PASS/FAIL and transferred values.
- `reports/dma_throughput.log`: D01-D09 latency, throughput, AXI transaction
  counts, burst lengths, Cycle-Stealing gaps, and Transparent wait cycles.
- `reports/dma_edge_cases.log`: detailed PASS/FAIL for E01-E20 edge/error tests.
- `reports/dma_9case_fmax.log`: post-route system, DMA-core, and IOMMU-core
  Fmax mapped to D01-D09.  Fmax is shared because all cases use one static
  implemented netlist; direction and mode change latency, not the clock path.

Run the component regression in an isolated XSim project with:

```tcl
source D:/DMA_MMU-main(1)/scripts/run_axi_edge_regression.tcl
```
