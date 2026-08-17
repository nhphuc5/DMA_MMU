# Hybrid DMA access control

## Why the flow is hybrid

There are two different command sources and they must not be treated as the
same authorization event:

1. **CPU-issued command**: firmware writes `START` or pushes a descriptor into
   the FIFO.  That software action is already the CPU decision to authorize
   the transfer.  The DMA starts without a second request/grant round trip.
2. **Peripheral-issued command**: UART RX may present data when no CPU command
   is active.  If autonomous mode is enabled, hardware captures an S2M request,
   raises IRQ, and waits.  Firmware reads the metadata and writes GRANT or DENY.

This removes redundant checks from normal D01-D09 and scatter-gather traffic,
while retaining CPU policy for a device that independently requests service.
The access controller is placed before the scheduler, so a denied request
cannot reach the IOMMU, AXI4, AXI-Stream data engine, or RAM.

## Autonomous UART request sequence

1. CPU programs the S2M template: destination IOVA, length, DMA mode, and burst.
2. CPU sets `ACCESS_CTRL[1:0] = 2'b11`.
3. UART RX assembles an AXI-Stream word and asserts `TVALID`.
4. DMA captures request metadata, sets `ACCESS_STATUS.pending`, and raises IRQ.
5. CPU reads the request and applies its software policy.
6. GRANT releases one command to the IOMMU and scheduler.  DENY completes with
   fault code `0x70` and produces no AXI memory access.
7. The IOMMU still translates IOVA to physical address and checks page range
   and read/write permission after CPU grant.

## AXI4-Lite register map

| Offset | Name | Meaning |
|---:|---|---|
| `0x70` | `ACCESS_CTRL` | bit 0: peripheral request needs GRANT/DENY; bit 1: enable UART autonomous request |
| `0x74` | `ACCESS_STATUS` | pending, active, denied, queued, type, mode, ID, peripheral origin |
| `0x78` | `ACCESS_CMD` | bit 0 GRANT, bit 1 DENY, bit 2 clear denied |
| `0x7c` | `ACCESS_SRC` | captured source IOVA |
| `0x80` | `ACCESS_DST` | captured destination IOVA |
| `0x84` | `ACCESS_LEN` | captured byte count |
| `0x88` | `ACCESS_INFO` | captured burst word count |

`ACCESS_STATUS` fields:

- bit 0: request pending;
- bit 1: granted command active;
- bit 2: sticky denied indication;
- bit 3: queued command (normally zero for autonomous UART);
- bits 5:4: transfer type;
- bits 7:6: DMA mode;
- bits 15:8: descriptor ID (`0xff` for autonomous UART);
- bit 16: request originated from a peripheral.

Both control bits reset to zero.  Therefore existing CPU-driven commands keep
their original behavior unless firmware explicitly enables autonomous UART.

## Verification

`tb_dma_mmu_axi_top.sv` proves four properties:

- CPU `START` runs immediately without a duplicate grant;
- CPU descriptor `PUSH` runs immediately and preserves completion ID/data;
- autonomous UART traffic raises IRQ and causes no AXI activity before GRANT;
- DENY returns fault `0x70`, performs no AXI write, and changes no RAM data.

`tb_dma_mmu_picorv32_soc.sv` executes real PicoRV32 firmware.  D01-D09 and all
eight queued descriptors run with implicit CPU authorization.  P01 then sends
real UART bytes `E0..E7` without writing START; exactly one access request and
one CPU grant must occur before RAM receives those bytes.
