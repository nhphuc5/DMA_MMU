/* PicoRV32 bare-metal C++ firmware for the complete DMA/IOMMU SoC.
 *
 * This program is intentionally freestanding: it does not use an operating
 * system, the C++ standard library, dynamic allocation, exceptions, or RTTI.
 * All observable PASS/FAIL results come from real MMIO, RAM, DMA, IOMMU and
 * UART activity checked by this firmware and the SystemVerilog testbench.
 *
 * UART verification protocol (kept compatible with the original firmware):
 *   S       firmware started
 *   M       CPU-side MMU non-identity translation passed
 *   1..9    DMA cases D01..D09 passed
 *   A/B/C   testbench shall send UART input for D04/D05/D06
 *   X/Y/Z   DMA-to-UART payload for D07/D08/D09 follows
 *   Q       eight-entry descriptor queue/scatter-gather test passed
 *   R       testbench shall send an autonomous UART request
 *   V       autonomous request was granted and its RAM data verified
 *   P       every firmware test passed
 *   F       firmware detected a hardware fault or data mismatch
 */

#include "soc_map.h"

using u32 = unsigned int;

// The RTL regression uses a deliberately small divider to keep simulation
// short.  Board builds override this macro from the Makefile.  For VC707 the
// SoC clock is 150 MHz and SOC_UART_DIVIDER=1300 produces approximately
// 115200 baud (the UART holds each bit for divider+2 clock cycles).
#ifndef SOC_UART_DIVIDER
#define SOC_UART_DIVIDER 4u
#endif

static_assert(sizeof(u32) == 4, "PicoRV32 firmware requires 32-bit unsigned int");

namespace {

constexpr u32 M2M_SOURCE = 0x00004000u;
constexpr u32 M2M_DEST   = 0x00005000u;
constexpr u32 S2M_DEST   = 0x00006000u;
constexpr u32 M2S_SOURCE = 0x00007000u;

constexpr u32 DMA_TYPE_M2M = 0u;
constexpr u32 DMA_TYPE_S2M = 1u;
constexpr u32 DMA_TYPE_M2S = 2u;

constexpr u32 DMA_MODE_BURST      = 0u;
constexpr u32 DMA_MODE_CYCLE      = 1u;
constexpr u32 DMA_MODE_TRANSPARENT = 2u;

constexpr u32 DMA_STATUS_DONE  = 1u << 1;
constexpr u32 DMA_STATUS_FAULT = 1u << 2;

inline volatile u32& memory_word(u32 address)
{
    return *reinterpret_cast<volatile u32*>(address);
}

inline void uart_putc(char value)
{
    UART_DATA = static_cast<u32>(static_cast<unsigned char>(value));
}

[[noreturn]] void fail()
{
    uart_putc('F');
    for (;;) {
        __asm__ volatile ("" ::: "memory");
    }
}

inline void expect_word(u32 address, u32 expected)
{
    if (memory_word(address) != expected) {
        fail();
    }
}

inline u32 dma_config(u32 type, u32 mode, u32 burst_words)
{
    return (burst_words << 8) | (mode << 2) | type;
}

void program_cpu_page(u32 index, u32 vpn, u32 ppn, u32 flags)
{
    CPU_MMU_PT_INDEX = index;
    CPU_MMU_PT_VPN   = vpn;
    CPU_MMU_PT_PPN   = ppn;
    CPU_MMU_PT_FLAGS = flags;
}

void program_iommu_page(u32 index, u32 vpn, u32 ppn, u32 flags)
{
    IOMMU_PT_INDEX = index;
    IOMMU_PT_VPN   = vpn;
    IOMMU_PT_PPN   = ppn;
    IOMMU_PT_FLAGS = flags;
}

void program_dma(u32 source, u32 destination, u32 length, u32 config)
{
    DMA_CONTROL      = 2u;  // Clear sticky DONE/FAULT.
    DMA_SRC_VADDR    = source;
    DMA_DST_VADDR    = destination;
    DMA_LENGTH_BYTES = length;
    DMA_CONFIG       = config;
}

void poll_dma()
{
    for (;;) {
        const u32 status = DMA_STATUS;
        if ((status & DMA_STATUS_FAULT) != 0u) {
            fail();
        }
        if ((status & DMA_STATUS_DONE) != 0u) {
            return;
        }
    }
}

void wait_uart_drain()
{
    // bit 3 = DMA word buffered, bit 0 = serial TX ready.
    while ((UART_STATUS & 0x9u) != 0x1u) {
    }
}

void configure_cpu_mmu()
{
    // Code page: identity mapped, valid/read/execute.
    program_cpu_page(0u, 0u, 0u,
                     CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ | CPU_MMU_PTE_EXEC);

    // Stack page: identity mapped, valid/read/write.
    program_cpu_page(15u, 15u, 15u,
                     CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ | CPU_MMU_PTE_WRITE);

    // DMA test buffers: identity mapped, valid/read/write.
    for (u32 page = 4u; page < 8u; ++page) {
        program_cpu_page(page, page, page,
                         CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ | CPU_MMU_PTE_WRITE);
    }

    // Deliberate non-identity mapping: VA page 8 -> physical page 3.
    program_cpu_page(8u, 8u, 3u,
                     CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ | CPU_MMU_PTE_WRITE);

    CPU_MMU_TLB_CTRL = CPU_MMU_TLB_INVALIDATE | CPU_MMU_CLEAR_STATS;
    CPU_MMU_CONTROL  = CPU_MMU_ENABLE;

    memory_word(0x00008000u) = 0xc0dec0deu;
    expect_word(0x00008000u, 0xc0dec0deu);

    // enabled=1 and fault_pending=0; at least one TLB miss must occur.
    if ((CPU_MMU_STATUS & 0x3u) != 0x1u || CPU_MMU_TLB_MISSES == 0u) {
        fail();
    }
    uart_putc('M');
}

void initialize_test_memory()
{
    // D01/D02/D03 source patterns.
    memory_word(M2M_SOURCE + 0x00u) = 0x11111111u;
    memory_word(M2M_SOURCE + 0x04u) = 0x22222222u;
    memory_word(M2M_SOURCE + 0x08u) = 0x33333333u;
    memory_word(M2M_SOURCE + 0x0cu) = 0x44444444u;
    memory_word(M2M_SOURCE + 0x20u) = 0x12121212u;
    memory_word(M2M_SOURCE + 0x24u) = 0x23232323u;
    memory_word(M2M_SOURCE + 0x40u) = 0x34343434u;
    memory_word(M2M_SOURCE + 0x44u) = 0x45454545u;

    // D07/D08/D09 bytes; the UART adapter emits the least-significant byte first.
    memory_word(M2S_SOURCE + 0x00u) = 0x13121110u;
    memory_word(M2S_SOURCE + 0x04u) = 0x17161514u;
    memory_word(M2S_SOURCE + 0x20u) = 0x23222120u;
    memory_word(M2S_SOURCE + 0x24u) = 0x27262524u;
    memory_word(M2S_SOURCE + 0x40u) = 0x33323130u;
    memory_word(M2S_SOURCE + 0x44u) = 0x37363534u;

    // Clear every destination so stale RAM cannot make a test pass.
    for (u32 offset = 0u; offset <= 0x0cu; offset += 4u) {
        memory_word(M2M_DEST + offset) = 0u;
    }
    memory_word(M2M_DEST + 0x20u) = 0u;
    memory_word(M2M_DEST + 0x24u) = 0u;
    memory_word(M2M_DEST + 0x40u) = 0u;
    memory_word(M2M_DEST + 0x44u) = 0u;
    memory_word(S2M_DEST + 0x00u) = 0u;
    memory_word(S2M_DEST + 0x04u) = 0u;
    memory_word(S2M_DEST + 0x20u) = 0u;
    memory_word(S2M_DEST + 0x24u) = 0u;
    memory_word(S2M_DEST + 0x40u) = 0u;
    memory_word(S2M_DEST + 0x44u) = 0u;
}

void configure_dma_iommu()
{
    // Page 4: M2M source, valid/read/write.
    program_iommu_page(4u, 4u, 4u, 7u);
    // Page 5: M2M destination, valid/read/write.
    program_iommu_page(5u, 5u, 5u, 7u);
    // Page 6: S2M destination, valid/write only.
    program_iommu_page(6u, 6u, 6u, 5u);
    // Page 7: M2S source, valid/read only.
    program_iommu_page(7u, 7u, 7u, 3u);

    // CPU START/PUSH is already authorization for CPU-originated work.
    DMA_ACCESS_CTRL = 0u;
}

void test_d01_m2m_burst()
{
    program_dma(M2M_SOURCE, M2M_DEST, 16u,
                dma_config(DMA_TYPE_M2M, DMA_MODE_BURST, 4u));
    DMA_CONTROL = 1u;
    poll_dma();
    expect_word(M2M_DEST + 0x00u, 0x11111111u);
    expect_word(M2M_DEST + 0x04u, 0x22222222u);
    expect_word(M2M_DEST + 0x08u, 0x33333333u);
    expect_word(M2M_DEST + 0x0cu, 0x44444444u);
    uart_putc('1');
}

void test_d02_m2m_cycle()
{
    program_dma(M2M_SOURCE + 0x20u, M2M_DEST + 0x20u, 8u,
                dma_config(DMA_TYPE_M2M, DMA_MODE_CYCLE, 1u));
    DMA_CONTROL = 1u;
    poll_dma();
    expect_word(M2M_DEST + 0x20u, 0x12121212u);
    expect_word(M2M_DEST + 0x24u, 0x23232323u);
    uart_putc('2');
}

void test_d03_m2m_transparent()
{
    program_dma(M2M_SOURCE + 0x40u, M2M_DEST + 0x40u, 8u,
                dma_config(DMA_TYPE_M2M, DMA_MODE_TRANSPARENT, 1u));
    DMA_CONTROL = 1u;
    poll_dma();
    expect_word(M2M_DEST + 0x40u, 0x34343434u);
    expect_word(M2M_DEST + 0x44u, 0x45454545u);
    uart_putc('3');
}

void test_d04_s2m_burst()
{
    program_dma(0u, S2M_DEST, 8u,
                dma_config(DMA_TYPE_S2M, DMA_MODE_BURST, 2u));
    DMA_CONTROL = 1u;
    uart_putc('A');
    poll_dma();
    expect_word(S2M_DEST + 0x00u, 0xa3a2a1a0u);
    expect_word(S2M_DEST + 0x04u, 0xa7a6a5a4u);
    uart_putc('4');
}

void test_d05_s2m_cycle()
{
    program_dma(0u, S2M_DEST + 0x20u, 8u,
                dma_config(DMA_TYPE_S2M, DMA_MODE_CYCLE, 1u));
    DMA_CONTROL = 1u;
    uart_putc('B');
    poll_dma();
    expect_word(S2M_DEST + 0x20u, 0xb3b2b1b0u);
    expect_word(S2M_DEST + 0x24u, 0xb7b6b5b4u);
    uart_putc('5');
}

void test_d06_s2m_transparent()
{
    program_dma(0u, S2M_DEST + 0x40u, 8u,
                dma_config(DMA_TYPE_S2M, DMA_MODE_TRANSPARENT, 1u));
    DMA_CONTROL = 1u;
    uart_putc('C');
    poll_dma();
    expect_word(S2M_DEST + 0x40u, 0xc3c2c1c0u);
    expect_word(S2M_DEST + 0x44u, 0xc7c6c5c4u);
    uart_putc('6');
}

void test_d07_m2s_burst()
{
    program_dma(M2S_SOURCE, 0u, 8u,
                dma_config(DMA_TYPE_M2S, DMA_MODE_BURST, 2u));
    uart_putc('X');
    DMA_CONTROL = 1u;
    poll_dma();
    wait_uart_drain();
    uart_putc('7');
}

void test_d08_m2s_cycle()
{
    program_dma(M2S_SOURCE + 0x20u, 0u, 8u,
                dma_config(DMA_TYPE_M2S, DMA_MODE_CYCLE, 1u));
    uart_putc('Y');
    DMA_CONTROL = 1u;
    poll_dma();
    wait_uart_drain();
    uart_putc('8');
}

void test_d09_m2s_transparent()
{
    program_dma(M2S_SOURCE + 0x40u, 0u, 8u,
                dma_config(DMA_TYPE_M2S, DMA_MODE_TRANSPARENT, 1u));
    uart_putc('Z');
    DMA_CONTROL = 1u;
    poll_dma();
    wait_uart_drain();
    uart_putc('9');
}

void test_descriptor_queue()
{
    // Initialize eight scattered source/destination words.
    for (u32 i = 0u; i < 8u; ++i) {
        const u32 source = M2M_SOURCE + 0x100u + (i << 5);
        const u32 destination = M2M_DEST + 0x200u + (i << 5);
        memory_word(source) = 0x51000000u + i;
        memory_word(destination) = 0u;
    }

    DMA_CONTROL = 2u;
    DMA_DESC_COMMAND = DMA_DESC_CMD_PAUSE;

    // Fill all eight FIFO entries before dispatch is resumed.
    for (u32 i = 0u; i < 8u; ++i) {
        DMA_DESC_SRC    = M2M_SOURCE + 0x100u + (i << 5);
        DMA_DESC_DST    = M2M_DEST + 0x200u + (i << 5);
        DMA_DESC_LENGTH = 4u;
        DMA_DESC_CONFIG = dma_config(DMA_TYPE_M2M, DMA_MODE_BURST, 4u);
        DMA_DESC_FLAGS  = (0x40u + i) << 8;
        DMA_DESC_NEXT   = 0u;
        DMA_DESC_COMMAND = DMA_DESC_CMD_PUSH;
    }
    DMA_DESC_COMMAND = DMA_DESC_CMD_RESUME;

    while (DMA_COMP_COUNT(DMA_QUEUE_STATUS) != 8u) {
    }

    // Verify real DMA data at all scattered destinations.
    for (u32 i = 0u; i < 8u; ++i) {
        const u32 source = M2M_SOURCE + 0x100u + (i << 5);
        const u32 destination = M2M_DEST + 0x200u + (i << 5);
        if (memory_word(destination) != memory_word(source)) {
            fail();
        }
    }

    // Completion FIFO must preserve ID order, DONE, and byte count.
    for (u32 i = 0u; i < 8u; ++i) {
        const u32 completion = DMA_COMP_STATUS;
        if ((completion >> 24) != (0x40u + i) ||
            (completion & 0x7u) != 0x3u || DMA_COMP_BYTES != 4u) {
            fail();
        }
        DMA_COMP_POP = 1u;
    }
    if (DMA_COMP_TOTAL != 8u) {
        fail();
    }
    uart_putc('Q');
}

void authorize_autonomous_dma()
{
    u32 status;
    do {
        status = DMA_ACCESS_STATUS;
    } while ((status & DMA_ACCESS_PENDING) == 0u);

    bool permitted = (status & DMA_ACCESS_PERIPHERAL) != 0u;
    permitted = permitted && DMA_ACCESS_LENGTH != 0u;

    const u32 mode = DMA_ACCESS_MODE(status);
    const u32 type = DMA_ACCESS_TYPE(status);
    permitted = permitted && mode != 3u && type <= DMA_TYPE_M2S;

    if (permitted) {
        if (type == DMA_TYPE_M2M) {
            permitted = (DMA_ACCESS_SRC >> 12) == 4u &&
                        (DMA_ACCESS_DST >> 12) == 5u;
        } else if (type == DMA_TYPE_S2M) {
            permitted = (DMA_ACCESS_DST >> 12) == 6u;
        } else {
            permitted = (DMA_ACCESS_SRC >> 12) == 7u;
        }
    }

    if (!permitted) {
        DMA_ACCESS_COMMAND = DMA_ACCESS_DENY;
        fail();
    }
    DMA_ACCESS_COMMAND = DMA_ACCESS_GRANT;
}

void test_autonomous_uart_request()
{
    memory_word(S2M_DEST + 0x60u) = 0u;
    memory_word(S2M_DEST + 0x64u) = 0u;

    DMA_CONTROL = 6u;  // Clear status and enable DMA IRQ.
    DMA_SRC_VADDR = 0u;
    DMA_DST_VADDR = S2M_DEST + 0x60u;
    DMA_LENGTH_BYTES = 8u;
    DMA_CONFIG = dma_config(DMA_TYPE_S2M, DMA_MODE_BURST, 2u);
    DMA_ACCESS_CTRL = DMA_ACCESS_PERIPH_GRANT_ENABLE |
                      DMA_ACCESS_PERIPH_REQUEST_ENABLE;

    uart_putc('R');  // Testbench sends real UART bytes E0..E7.
    authorize_autonomous_dma();
    poll_dma();
    DMA_ACCESS_CTRL = 0u;

    expect_word(S2M_DEST + 0x60u, 0xe3e2e1e0u);
    expect_word(S2M_DEST + 0x64u, 0xe7e6e5e4u);
    uart_putc('V');
}

} // namespace

extern "C" [[noreturn]] void firmware_main()
{
    UART_DIVIDER = SOC_UART_DIVIDER;
    uart_putc('S');

    configure_cpu_mmu();
    initialize_test_memory();
    configure_dma_iommu();

    test_d01_m2m_burst();
    test_d02_m2m_cycle();
    test_d03_m2m_transparent();
    test_d04_s2m_burst();
    test_d05_s2m_cycle();
    test_d06_s2m_transparent();
    test_d07_m2s_burst();
    test_d08_m2s_cycle();
    test_d09_m2s_transparent();
    test_descriptor_queue();
    test_autonomous_uart_request();

    uart_putc('P');
    for (;;) {
        __asm__ volatile ("" ::: "memory");
    }
}

/* A CPU reset does not provide a C/C++ runtime.  These two instructions are
 * the only architecture-specific startup code required: establish the stack
 * at the top of the 64-KiB RAM and enter the freestanding C++ firmware.
 */
extern "C" [[gnu::naked, gnu::used, gnu::section(".text.start"), noreturn]]
void _start()
{
    __asm__ volatile (
        "li sp, 0x10000\n"
        "j firmware_main\n"
    );
}
