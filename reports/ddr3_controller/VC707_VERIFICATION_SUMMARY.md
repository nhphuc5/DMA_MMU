# VC707 license and controller verification

Verification date: 2026-08-17  
Vivado: 2025.1  
Part: `xc7vx485tffg1761-2`
License file SHA-256:
`B6524EDE15F7896CD4198D2E89C7F782B733083D5C4D36071C5E7E2278A6E45C`

The fingerprint identifies the tested file without publishing the license.

## What passed

- The supplied license checked out both the `Synthesis` and `Implementation`
  features for device `xc7vx485t`.
- Out-of-context synthesis, optimization, placement, routing and post-route
  physical optimization of `axi_ddr3_controller` completed successfully.
- Final route status had zero unrouted nets.
- At a 3.000 ns constraint, routed WNS was +0.204 ns and routed WHS was
  +0.134 ns. The corresponding block-only Fmax estimate is 357.654 MHz.
- Routed utilization was 589 LUTs, 576 flip-flops, 0 BRAMs and 0 DSPs.

Primary evidence:

- `vivado_vc707_license_implementation.log`: license checkout and the complete
  Vivado implementation transcript;
- `implementation_summary.txt`: concise part, slack, Fmax and DSP result;
- `utilization_routed.rpt`: routed hierarchical resource report;
- `timing_routed.rpt`: routed timing report.

## What this does not prove

This run implements only the project-owned AXI/DFI-lite digital controller as
an out-of-context block. It does not contain or test the VC707 x64 DDR3 PHY,
pin-level datapath, calibration/training logic, SODIMM pins or DDR XDC.
`vc707_phy_audit.log` records that these objects are absent from the current
board RTL/constraints, and `ENABLE_DDR3` remains disabled by default.

The OOC router also reports missing `HD.PARTPIN_LOCS` for interface ports, so
357.654 MHz is an estimate for the isolated block, not a timing guarantee for
the final SoC plus PHY. Physical DDR3 operation can only be claimed after a PHY
is integrated, full-chip timing closes, calibration succeeds and memory stress
tests pass on a VC707 board.
