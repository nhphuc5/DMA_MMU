# UART peripheral

- `simpleuart_dma.sv`: byte-level 8N1 UART transmitter/receiver.
- `uart_apb_axis.sv`: APB register bank plus AXI4-Stream DMA data interface.
- `../AXI/axil_to_apb_bridge.sv`: converts CPU AXI4-Lite control accesses to APB.

The control path is `PicoRV32 router -> AXI4-Lite/APB bridge -> UART`.
The payload path is independent: `UART AXI4-Stream <-> DMA`.
