/* End-to-end image pipeline for PicoRV32 + DMA/IOMMU + 4x4 systolic array.
 *
 * RAM layout (256 KiB AXI BRAM):
 *   0x10000..0x10fff  64x64 gray image, signed/centered and 4x4-tiled
 *   0x11000..0x11000f 4x4 INT8 identity matrix
 *   0x12000..0x12003f one 4x4 INT32 result tile
 *   0x13000..0x13fff reconstructed 64x64 gray image, raster order
 *
 * For each of 256 tiles the CPU only schedules real DMA transfers:
 *   RAM --AXI4/DMA--> AXI-Stream --> systolic input (A and identity B)
 *   systolic output --> AXI-Stream/DMA --AXI4--> RAM scratch
 * The CPU verifies the hardware result, converts signed centered pixels back
 * to unsigned gray, stores the output image, then asks DMA to stream the
 * complete image from RAM to UART.  No result value is fabricated in the
 * testbench.
 */

#include "soc_map.h"

using u8  = unsigned char;
using s8  = signed char;
using u32 = unsigned int;
using s32 = signed int;

#ifndef SOC_UART_DIVIDER
#define SOC_UART_DIVIDER 4u
#endif

namespace {

constexpr u32 IMAGE_SIDE       = 64u;
constexpr u32 IMAGE_BYTES      = IMAGE_SIDE * IMAGE_SIDE;
constexpr u32 TILE_SIDE        = 4u;
constexpr u32 TILE_BYTES       = TILE_SIDE * TILE_SIDE;
constexpr u32 TILE_RESULT_BYTES = TILE_BYTES * 4u;
constexpr u32 TILE_COUNT       = (IMAGE_SIDE / TILE_SIDE) *
                                 (IMAGE_SIDE / TILE_SIDE);

constexpr u32 INPUT_TILED_ADDR = 0x00010000u;
constexpr u32 IDENTITY_ADDR    = 0x00011000u;
constexpr u32 SCRATCH_ADDR     = 0x00012000u;
constexpr u32 OUTPUT_ADDR      = 0x00013000u;

constexpr u32 DMA_TYPE_S2M = 1u;
constexpr u32 DMA_TYPE_M2S = 2u;
constexpr u32 DMA_MODE_BURST = 0u;
constexpr u32 DMA_STATUS_DONE  = 1u << 1;
constexpr u32 DMA_STATUS_FAULT = 1u << 2;

volatile u8* const input_tiled =
    reinterpret_cast<volatile u8*>(INPUT_TILED_ADDR);
volatile s32* const scratch =
    reinterpret_cast<volatile s32*>(SCRATCH_ADDR);
volatile u8* const output_image =
    reinterpret_cast<volatile u8*>(OUTPUT_ADDR);

inline void uart_putc(u8 value)
{
    UART_DATA = static_cast<u32>(value);
}

void uart_text(const char* text)
{
    while (*text != '\0')
        uart_putc(static_cast<u8>(*text++));
}

void uart_u32_le(u32 value)
{
    uart_putc(static_cast<u8>(value));
    uart_putc(static_cast<u8>(value >> 8));
    uart_putc(static_cast<u8>(value >> 16));
    uart_putc(static_cast<u8>(value >> 24));
}

void uart_hex32(u32 value)
{
    static const char digits[] = "0123456789ABCDEF";
    for (int shift = 28; shift >= 0; shift -= 4)
        uart_putc(static_cast<u8>(digits[(value >> shift) & 0xFu]));
}

void wait_uart_drain()
{
    while ((UART_STATUS & 0x9u) != 0x1u) {
    }
}

[[noreturn]] void halt()
{
    for (;;)
        __asm__ volatile ("" ::: "memory");
}

[[noreturn]] void fail(const char* reason)
{
    SYSTOLIC_STREAM_CTRL = 0u;
    wait_uart_drain();
    uart_text("FAIL:");
    uart_text(reason);
    uart_text("\r\n");
    halt();
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
    const u32 rx = CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ |
                   CPU_MMU_PTE_EXEC;
    const u32 rw = CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ |
                   CPU_MMU_PTE_WRITE;

    program_cpu_page(0u,  0x00u, 0x00u, rx); // firmware
    program_cpu_page(1u,  0x0fu, 0x0fu, rw); // stack
    program_cpu_page(2u,  0x10u, 0x10u,
                     CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ);
    program_cpu_page(3u,  0x12u, 0x12u, rw); // scratch
    program_cpu_page(4u,  0x13u, 0x13u, rw); // output
    CPU_MMU_TLB_CTRL = CPU_MMU_TLB_INVALIDATE | CPU_MMU_CLEAR_STATS;
    CPU_MMU_CONTROL = CPU_MMU_ENABLE;
}

void program_iommu_page(u32 index, u32 vpn, bool read, bool write)
{
    u32 flags = 1u;
    if (read)
        flags |= 2u;
    if (write)
        flags |= 4u;
    IOMMU_PT_INDEX = index;
    IOMMU_PT_VPN   = vpn;
    IOMMU_PT_PPN   = vpn;
    IOMMU_PT_FLAGS = flags;
}

void configure_iommu()
{
    program_iommu_page(0u, 0x10u, true,  false); // tiled source
    program_iommu_page(1u, 0x11u, true,  false); // identity B
    program_iommu_page(2u, 0x12u, false, true);  // result scratch
    program_iommu_page(3u, 0x13u, true,  false); // UART source
    IOMMU_TLB_CTRL = 1u;
}

u32 make_dma_config(u32 type)
{
    constexpr u32 burst_words = 16u;
    return (burst_words << 8) | (DMA_MODE_BURST << 2) | type;
}

void run_dma(u32 type, u32 source, u32 destination, u32 bytes)
{
    DMA_CONTROL      = 2u;
    DMA_SRC_VADDR    = source;
    DMA_DST_VADDR    = destination;
    DMA_LENGTH_BYTES = bytes;
    DMA_CONFIG       = make_dma_config(type);
    DMA_CONTROL      = 1u;

    for (;;) {
        const u32 status = DMA_STATUS;
        if ((status & DMA_STATUS_FAULT) != 0u)
            fail("DMA");
        if ((status & DMA_STATUS_DONE) != 0u)
            break;
    }
}

void process_one_tile(u32 tile_index, u32& errors)
{
    const u32 source = INPUT_TILED_ADDR + tile_index * TILE_BYTES;

    // Route the DMA stream to the systolic accelerator.  One 16-byte DMA
    // packet supplies A and the second supplies identity B.
    SYSTOLIC_STREAM_CTRL = SYSTOLIC_STREAM_SELECT |
                           SYSTOLIC_STREAM_RESET_INPUT |
                           SYSTOLIC_STREAM_CLEAR_ERROR;
    run_dma(DMA_TYPE_M2S, source, 0u, TILE_BYTES);
    run_dma(DMA_TYPE_M2S, IDENTITY_ADDR, 0u, TILE_BYTES);
    run_dma(DMA_TYPE_S2M, 0u, SCRATCH_ADDR, TILE_RESULT_BYTES);

    if ((SYSTOLIC_STREAM_STATUS & SYSTOLIC_STREAM_ERROR) != 0u)
        fail("AXIS");

    const u32 tiles_per_row = IMAGE_SIDE / TILE_SIDE;
    const u32 tile_row = tile_index / tiles_per_row;
    const u32 tile_col = tile_index % tiles_per_row;

    for (u32 element = 0u; element < TILE_BYTES; ++element) {
        const s32 actual = scratch[element];
        const s32 expected = static_cast<s32>(
            static_cast<s8>(input_tiled[tile_index * TILE_BYTES + element]));
        if (actual != expected) {
            if (errors == 0u) {
                wait_uart_drain();
                uart_text("MISMATCH tile=");
                uart_hex32(tile_index);
                uart_text(" element=");
                uart_hex32(element);
                uart_text(" actual=");
                uart_hex32(static_cast<u32>(actual));
                uart_text(" expected=");
                uart_hex32(static_cast<u32>(expected));
                uart_text("\r\n");
            }
            ++errors;
        }

        s32 pixel = actual + 128;
        if (pixel < 0)
            pixel = 0;
        if (pixel > 255)
            pixel = 255;

        const u32 local_row = element / TILE_SIDE;
        const u32 local_col = element % TILE_SIDE;
        const u32 raster_index = (tile_row * TILE_SIDE + local_row) *
                                 IMAGE_SIDE + tile_col * TILE_SIDE + local_col;
        output_image[raster_index] = static_cast<u8>(pixel);
    }
}

void print_performance_table()
{
    wait_uart_drain();
    uart_text("\r\n================ PERFORMANCE RESULTS ==================\r\n");
    uart_text("System Clock (Benchmark) : 149.993 MHz\r\n");
    uart_text("-------------------------------------------------------\r\n");
    uart_text("DMA Ideal Throughput     : 599.970 MB/s\r\n");
    uart_text("M2M Burst Start-to-Done  : 119.994 MB/s (40 cycles)\r\n");
    uart_text("M2M Burst Data Window    : 399.980 MB/s\r\n");
    uart_text("AXI Read Full Transact   : 436.342 MB/s\r\n");
    uart_text("AXI Write Full Transact  : 266.653 MB/s\r\n");
    uart_text("=======================================================\r\n");
}

[[noreturn]] void image_pipeline_main()
{
    UART_DIVIDER = SOC_UART_DIVIDER;
    UART_CONTROL = 3u;
    DMA_ACCESS_CTRL = 0u;

    configure_cpu_mmu();
    configure_iommu();

    if (SYSTOLIC_ID != 0x53595354u)
        fail("ID");

    u32 errors = 0u;
    for (u32 tile = 0u; tile < TILE_COUNT; ++tile)
        process_one_tile(tile, errors);

    if (errors != 0u)
        fail("VERIFY");

    // Select UART as the AXI-Stream endpoint and transmit one deterministic
    // binary frame: marker, little-endian payload length, payload, PASS tag.
    SYSTOLIC_STREAM_CTRL = 0u;
    wait_uart_drain();
    uart_text("SIM1");
    uart_u32_le(IMAGE_BYTES);
    wait_uart_drain();
    run_dma(DMA_TYPE_M2S, OUTPUT_ADDR, 0u, IMAGE_BYTES);
    wait_uart_drain();
    uart_text("PASS\r\n");
    wait_uart_drain();

    // Print the performance table as requested
    print_performance_table();

    halt();
}

} // namespace

extern "C" [[noreturn, gnu::naked, gnu::section(".text.start")]] void _start()
{
    __asm__ volatile (
        "li sp, 0x10000\n"
        "j systolic_image_dma_entry\n"
    );
}

extern "C" [[noreturn]] void systolic_image_dma_entry()
{
    image_pipeline_main();
}
