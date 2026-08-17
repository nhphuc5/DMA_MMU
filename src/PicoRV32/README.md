# PicoRV32

- `picorv32.v`: the single PicoRV32 CPU core and its internal helper modules.
- `picorv32_axil_router.sv`: routes CPU AXI4-Lite accesses to RAM, DMA/IOMMU
  registers, or UART registers and generates the CPU-bus-idle indication.

