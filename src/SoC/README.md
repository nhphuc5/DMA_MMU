# Integration tops

- `dma_mmu_axi_top.sv`: reusable DMA + DMA-side IOMMU IP with AXI4-Lite
  control, AXI4-Full memory master, and AXI-Stream peripheral ports.
- `dma_mmu_picorv32_soc.sv`: complete PicoRV32 + DMA/IOMMU + UART + shared AXI
  crossbar + AXI RAM system; this is the synthesis top.

