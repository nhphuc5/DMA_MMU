# AXI infrastructure

This directory contains reusable AXI plumbing rather than DMA policy:

- `axi_crossbar*.v`: independent AXI read/write routing and arbitration.
- `arbiter.v`, `priority_encoder.v`: arbitration helper logic.
- `axi_register_*.v`: optional AXI channel register slices.
- `axi_ram.v`: AXI4 memory model/implementation initialized by firmware HEX.

