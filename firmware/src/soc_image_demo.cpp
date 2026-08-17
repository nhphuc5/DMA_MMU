/* PicoRV32 image-to-UART DMA demonstration.
 *
 * Three 64x64 grayscale images are preloaded in AXI RAM at 0x8000, 0x9000
 * and 0xA000.  Firmware programs the DMA-side IOMMU, then starts three real
 * memory-to-peripheral DMA transfers.  The UART byte stream is:
 *
 *   "IMG1" + 4096 raw gray bytes
 *   "IMG2" + 4096 raw gray bytes
 *   "IMG3" + 4096 raw gray bytes
 *   "DONE"
 *
 * The CPU only configures the transfer.  Image payload bytes are read from
 * RAM by the DMA AXI4 master and delivered to UART over AXI-Stream.
 */

#include "soc_map.h"

using u32 = unsigned int;

#ifndef SOC_UART_DIVIDER
#define SOC_UART_DIVIDER 4u
#endif

namespace {

constexpr u32 IMAGE_BYTES = 64u * 64u;
constexpr u32 IMAGE_ADDR[3] = {0x00008000u, 0x00009000u, 0x0000A000u};

constexpr u32 DMA_TYPE_M2S  = 2u;
constexpr u32 DMA_MODE_BURST = 0u;
constexpr u32 DMA_STATUS_DONE  = 1u << 1;
constexpr u32 DMA_STATUS_FAULT = 1u << 2;

inline void uart_putc(char value)
{
    // The UART AXI4-Lite slave applies backpressure while its CPU byte buffer
    // is occupied, so completion of this store means that the byte was taken.
    UART_DATA = static_cast<u32>(static_cast<unsigned char>(value));
}

void uart_text(const char* text)
{
    while (*text != '\0') {
        uart_putc(*text++);
    }
}

void wait_uart_drain()
{
    // bit 3 = DMA word buffered; bit 0 = serial transmitter ready.
    while ((UART_STATUS & 0x9u) != 0x1u) {
    }
}

[[noreturn]] void stop_with_error()
{
    wait_uart_drain();
    uart_text("ERR!");
    for (;;) {
        __asm__ volatile ("" ::: "memory");
    }
}

void program_cpu_page(u32 index, u32 vpn, u32 ppn, u32 flags)
{
    CPU_MMU_PT_INDEX = index;
    CPU_MMU_PT_VPN   = vpn;
    CPU_MMU_PT_PPN   = ppn;
    CPU_MMU_PT_FLAGS = flags;
}

void configure_cpu_mmu()
{
    // CPU executes firmware from page 0 and uses its stack in page 15.
    // Image payload is read by DMA, not by the CPU, so CPU mappings for the
    // image pages are deliberately unnecessary.
    program_cpu_page(0u, 0u, 0u,
        CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ | CPU_MMU_PTE_EXEC);
    program_cpu_page(15u, 15u, 15u,
        CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ | CPU_MMU_PTE_WRITE);
    CPU_MMU_TLB_CTRL = CPU_MMU_TLB_INVALIDATE | CPU_MMU_CLEAR_STATS;
    CPU_MMU_CONTROL = CPU_MMU_ENABLE;
}

void program_iommu_read_page(u32 page)
{
    IOMMU_PT_INDEX = page;
    IOMMU_PT_VPN   = page;
    IOMMU_PT_PPN   = page;
    IOMMU_PT_FLAGS = 3u; // valid + read permission
}

u32 dma_config()
{
    constexpr u32 burst_words = 16u;
    return (burst_words << 8) | (DMA_MODE_BURST << 2) | DMA_TYPE_M2S;
}

void dma_send_image(u32 source)
{
    wait_uart_drain();
    DMA_CONTROL      = 2u; // clear sticky DONE/FAULT
    DMA_SRC_VADDR    = source;
    DMA_DST_VADDR    = 0u; // AXI-Stream destination has no memory address
    DMA_LENGTH_BYTES = IMAGE_BYTES;
    DMA_CONFIG       = dma_config();
    DMA_CONTROL      = 1u; // START

    for (;;) {
        const u32 status = DMA_STATUS;
        if ((status & DMA_STATUS_FAULT) != 0u) {
            stop_with_error();
        }
        if ((status & DMA_STATUS_DONE) != 0u) {
            break;
        }
    }
    wait_uart_drain();
}

void send_header(u32 image_id)
{
    uart_putc('I');
    uart_putc('M');
    uart_putc('G');
    uart_putc(static_cast<char>('0' + image_id));
    wait_uart_drain();
}

[[noreturn]] void image_demo_main()
{
    UART_DIVIDER = SOC_UART_DIVIDER;
    UART_CONTROL = 3u; // enable DMA TX and RX paths
    DMA_ACCESS_CTRL = 0u; // CPU-issued descriptors execute immediately

    configure_cpu_mmu();
    program_iommu_read_page(8u);
    program_iommu_read_page(9u);
    program_iommu_read_page(10u);
    IOMMU_TLB_CTRL = 1u; // invalidate stale translations

    for (u32 index = 0u; index < 3u; ++index) {
        send_header(index + 1u);
        dma_send_image(IMAGE_ADDR[index]);
    }
    uart_text("DONE");

    for (;;) {
        __asm__ volatile ("" ::: "memory");
    }
}

} // namespace

extern "C" [[noreturn, gnu::naked, gnu::section(".text.start")]] void _start()
{
    __asm__ volatile (
        "li sp, 0x10000\n"
        "j image_demo_entry\n"
    );
}

extern "C" [[noreturn]] void image_demo_entry()
{
    image_demo_main();
}
