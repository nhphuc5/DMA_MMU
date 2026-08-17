# DMA

- `dma_axil_regs.sv`: AXI4-Lite control/status register bank programmed by the CPU.
- `dma_axi_scheduler.sv`: DMA command scheduler/FSM; selects direction and Burst,
  Cycle-Stealing, or Transparent mode, and requests IOMMU translation.
- `axi_cdma.v`: AXI memory-to-memory transfer engine.
- `axi_dma_rd.v`: AXI memory-read to AXI-Stream peripheral engine.
- `axi_dma_wr.v`: AXI-Stream peripheral to AXI memory-write engine.

