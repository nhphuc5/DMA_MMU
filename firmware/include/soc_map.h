#ifndef DMA_MMU_PICORV32_SOC_MAP_H
#define DMA_MMU_PICORV32_SOC_MAP_H

#define SOC_RAM_BASE        0x00000000u
#define SOC_DMA_BASE        0x10000000u
#define SOC_UART_BASE       0x20000000u
#define SOC_CPU_MMU_BASE    0x30000000u
#define SOC_SYSTOLIC_BASE   0x40000000u

/* 4x4 signed INT8 systolic matrix multiplier.  Each A/B row register packs
 * four signed 8-bit values in little-endian byte order.  Results are signed
 * 32-bit values in row-major order. */
#define SYSTOLIC_CONTROL    (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x00u))
#define SYSTOLIC_STATUS     (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x04u))
#define SYSTOLIC_CONFIG     (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x08u))
#define SYSTOLIC_CYCLES     (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x0cu))
#define SYSTOLIC_A_ROW(i)   (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x10u + 4u*(i)))
#define SYSTOLIC_B_ROW(i)   (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x20u + 4u*(i)))
#define SYSTOLIC_C_ELEM(i)  (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x40u + 4u*(i)))
#define SYSTOLIC_ID         (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x80u))
#define SYSTOLIC_STREAM_CTRL   (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x84u))
#define SYSTOLIC_STREAM_STATUS (*(volatile unsigned *)(SOC_SYSTOLIC_BASE + 0x88u))
#define SYSTOLIC_START      (1u << 0)
#define SYSTOLIC_CLEAR_DONE (1u << 1)
#define SYSTOLIC_BUSY       (1u << 0)
#define SYSTOLIC_DONE       (1u << 1)
#define SYSTOLIC_STREAM_SELECT      (1u << 0)
#define SYSTOLIC_STREAM_RESET_INPUT (1u << 1)
#define SYSTOLIC_STREAM_CLEAR_ERROR (1u << 2)
#define SYSTOLIC_STREAM_INPUT_READY (1u << 1)
#define SYSTOLIC_STREAM_COMPUTING   (1u << 2)
#define SYSTOLIC_STREAM_RESULT      (1u << 3)
#define SYSTOLIC_STREAM_ERROR       (1u << 16)

/* CPU-side MMU.  This block translates PicoRV32 instruction/data virtual
 * addresses.  It is independent from the DMA-side IOMMU below. */
#define CPU_MMU_PT_INDEX    (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x00u))
#define CPU_MMU_PT_VPN      (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x04u))
#define CPU_MMU_PT_PPN      (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x08u))
#define CPU_MMU_PT_FLAGS    (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x0cu))
#define CPU_MMU_TLB_CTRL    (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x10u))
#define CPU_MMU_CONTROL     (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x14u))
#define CPU_MMU_STATUS      (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x18u))
#define CPU_MMU_FAULT_VA    (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x1cu))
#define CPU_MMU_TLB_HITS    (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x20u))
#define CPU_MMU_TLB_MISSES  (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x24u))
#define CPU_MMU_CONFIG      (*(volatile unsigned *)(SOC_CPU_MMU_BASE + 0x28u))

#define CPU_MMU_PTE_VALID   (1u << 0)
#define CPU_MMU_PTE_READ    (1u << 1)
#define CPU_MMU_PTE_WRITE   (1u << 2)
#define CPU_MMU_PTE_EXEC    (1u << 3)
#define CPU_MMU_ENABLE      (1u << 0)
#define CPU_MMU_TLB_INVALIDATE (1u << 0)
#define CPU_MMU_CLEAR_STATS    (1u << 1)
#define CPU_MMU_CLEAR_FAULT    (1u << 2)

#define DMA_CONTROL         (*(volatile unsigned *)(SOC_DMA_BASE + 0x00u))
#define DMA_STATUS          (*(volatile unsigned *)(SOC_DMA_BASE + 0x04u))
#define DMA_SRC_VADDR       (*(volatile unsigned *)(SOC_DMA_BASE + 0x08u))
#define DMA_DST_VADDR       (*(volatile unsigned *)(SOC_DMA_BASE + 0x0cu))
#define DMA_LENGTH_BYTES    (*(volatile unsigned *)(SOC_DMA_BASE + 0x10u))
#define DMA_CONFIG          (*(volatile unsigned *)(SOC_DMA_BASE + 0x14u))
#define DMA_FAULT           (*(volatile unsigned *)(SOC_DMA_BASE + 0x18u))
#define IOMMU_PT_INDEX      (*(volatile unsigned *)(SOC_DMA_BASE + 0x20u))
#define IOMMU_PT_VPN        (*(volatile unsigned *)(SOC_DMA_BASE + 0x24u))
#define IOMMU_PT_PPN        (*(volatile unsigned *)(SOC_DMA_BASE + 0x28u))
#define IOMMU_PT_FLAGS      (*(volatile unsigned *)(SOC_DMA_BASE + 0x2cu))
#define IOMMU_TLB_CTRL      (*(volatile unsigned *)(SOC_DMA_BASE + 0x30u))
#define IOMMU_TLB_HITS      (*(volatile unsigned *)(SOC_DMA_BASE + 0x34u))
#define IOMMU_TLB_MISSES    (*(volatile unsigned *)(SOC_DMA_BASE + 0x38u))

/* Eight-entry descriptor queue staging registers.  Fill 0x40..0x54, then
 * write DMA_DESC_CMD_PUSH.  DESC_NEXT is retained as scatter-gather metadata;
 * this revision executes the eight descriptors already resident in the FIFO.
 */
#define DMA_DESC_SRC        (*(volatile unsigned *)(SOC_DMA_BASE + 0x40u))
#define DMA_DESC_DST        (*(volatile unsigned *)(SOC_DMA_BASE + 0x44u))
#define DMA_DESC_LENGTH     (*(volatile unsigned *)(SOC_DMA_BASE + 0x48u))
#define DMA_DESC_CONFIG     (*(volatile unsigned *)(SOC_DMA_BASE + 0x4cu))
#define DMA_DESC_FLAGS      (*(volatile unsigned *)(SOC_DMA_BASE + 0x50u))
#define DMA_DESC_NEXT       (*(volatile unsigned *)(SOC_DMA_BASE + 0x54u))
#define DMA_DESC_COMMAND    (*(volatile unsigned *)(SOC_DMA_BASE + 0x58u))
#define DMA_QUEUE_STATUS    (*(volatile unsigned *)(SOC_DMA_BASE + 0x5cu))
#define DMA_COMP_STATUS     (*(volatile unsigned *)(SOC_DMA_BASE + 0x60u))
#define DMA_COMP_BYTES      (*(volatile unsigned *)(SOC_DMA_BASE + 0x64u))
#define DMA_COMP_POP        (*(volatile unsigned *)(SOC_DMA_BASE + 0x68u))
#define DMA_COMP_TOTAL      (*(volatile unsigned *)(SOC_DMA_BASE + 0x6cu))

/* Hybrid DMA authorization.
 *
 * CPU-issued START and descriptor PUSH commands are already authorized by
 * software and therefore execute immediately.  Bit 1 optionally lets an
 * external AXI-Stream source (UART RX in this SoC) create an autonomous S2M
 * request.  When bit 0 is also set, only that autonomous request stops before
 * IOMMU/AXI activity and raises IRQ until firmware writes GRANT or DENY. */
#define DMA_ACCESS_CTRL     (*(volatile unsigned *)(SOC_DMA_BASE + 0x70u))
#define DMA_ACCESS_STATUS   (*(volatile unsigned *)(SOC_DMA_BASE + 0x74u))
#define DMA_ACCESS_COMMAND  (*(volatile unsigned *)(SOC_DMA_BASE + 0x78u))
#define DMA_ACCESS_SRC      (*(volatile unsigned *)(SOC_DMA_BASE + 0x7cu))
#define DMA_ACCESS_DST      (*(volatile unsigned *)(SOC_DMA_BASE + 0x80u))
#define DMA_ACCESS_LENGTH   (*(volatile unsigned *)(SOC_DMA_BASE + 0x84u))
#define DMA_ACCESS_INFO     (*(volatile unsigned *)(SOC_DMA_BASE + 0x88u))

#define DMA_ACCESS_PERIPH_GRANT_ENABLE   (1u << 0)
#define DMA_ACCESS_PERIPH_REQUEST_ENABLE (1u << 1)
/* Compatibility alias for older firmware sources. */
#define DMA_ACCESS_MANUAL_ENABLE DMA_ACCESS_PERIPH_GRANT_ENABLE
#define DMA_ACCESS_GRANT         (1u << 0)
#define DMA_ACCESS_DENY          (1u << 1)
#define DMA_ACCESS_CLEAR_DENIED  (1u << 2)
#define DMA_ACCESS_PENDING       (1u << 0)
#define DMA_ACCESS_ACTIVE        (1u << 1)
#define DMA_ACCESS_DENIED        (1u << 2)
#define DMA_ACCESS_QUEUED        (1u << 3)
#define DMA_ACCESS_PERIPHERAL    (1u << 16)
#define DMA_ACCESS_TYPE(v)       (((v) >> 4) & 0x3u)
#define DMA_ACCESS_MODE(v)       (((v) >> 6) & 0x3u)
#define DMA_ACCESS_ID(v)         (((v) >> 8) & 0xffu)

#define DMA_DESC_CMD_PUSH   (1u << 0)
#define DMA_DESC_CMD_FLUSH  (1u << 1)
#define DMA_DESC_CMD_RESUME (1u << 2)
#define DMA_DESC_CMD_PAUSE  (1u << 3)
#define DMA_QUEUE_COUNT(v)  ((v) & 0x0fu)
#define DMA_QUEUE_EMPTY     (1u << 8)
#define DMA_QUEUE_FULL      (1u << 9)
#define DMA_QUEUE_ACTIVE    (1u << 10)
#define DMA_QUEUE_HALTED    (1u << 11)
#define DMA_QUEUE_OVERFLOW  (1u << 12)
#define DMA_COMP_VALID      (1u << 13)
#define DMA_QUEUE_PAUSED    (1u << 14)
#define DMA_COMP_COUNT(v)   (((v) >> 16) & 0x0fu)

#define UART_DIVIDER        (*(volatile unsigned *)(SOC_UART_BASE + 0x00u))
#define UART_DATA           (*(volatile unsigned *)(SOC_UART_BASE + 0x04u))
#define UART_STATUS         (*(volatile unsigned *)(SOC_UART_BASE + 0x08u))
#define UART_CONTROL        (*(volatile unsigned *)(SOC_UART_BASE + 0x0cu))

#endif
