# DMA-side IOMMU

- `dma_iommu_tlb.sv`: 16-entry software page table, 4-entry fully associative
  TLB, address translation, range/permission checks, and fault response.
- `pseudoLRU.sv`: selects a TLB replacement entry when no invalid entry remains.

This IOMMU protects DMA accesses only; it is not a CPU instruction/data MMU.

