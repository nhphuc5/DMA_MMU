/* VC707 bare-metal DDR3 acceptance test.
 *
 * The program executes from the retained 64-KiB AXI RAM, waits for real MIG
 * calibration, then tests CPU word/narrow accesses, data/address lines,
 * checkerboard and pseudo-random patterns, and DMA/IOMMU copies in both
 * directions between BRAM and DDR3.  Results are printed on USB-UART.
 */

#include "soc_map.h"

using u8 = unsigned char;
using u16 = unsigned short;
using u32 = unsigned int;

#ifndef SOC_UART_DIVIDER
#define SOC_UART_DIVIDER 1300u
#endif

static_assert(sizeof(u8) == 1 && sizeof(u16) == 2 && sizeof(u32) == 4,
              "Unexpected RV32 type widths");

namespace {

constexpr u32 DDR_BASE = SOC_DDR_BASE;
constexpr u32 DDR_DMA_AREA = DDR_BASE + 0x00200000u;
constexpr u32 BRAM_DMA_SRC = 0x00004000u;
constexpr u32 BRAM_DMA_DST = 0x00006000u;
constexpr u32 TEST_WORDS = 16384u; // 64 KiB per bulk pattern test.
constexpr u32 DMA_BYTES = 256u;

constexpr u32 DMA_STATUS_DONE = 1u << 1;
constexpr u32 DMA_STATUS_FAULT = 1u << 2;
constexpr u32 DMA_TYPE_M2M = 0u;
constexpr u32 DMA_MODE_BURST = 0u;

inline volatile u32& word(u32 address)
{
    return *reinterpret_cast<volatile u32*>(address);
}

inline volatile u16& half(u32 address)
{
    return *reinterpret_cast<volatile u16*>(address);
}

inline volatile u8& byte(u32 address)
{
    return *reinterpret_cast<volatile u8*>(address);
}

inline void uart_putc(char value)
{
    UART_DATA = static_cast<u32>(static_cast<u8>(value));
}

void uart_puts(const char* text)
{
    while (*text != '\0')
        uart_putc(*text++);
}

void uart_hex(u32 value)
{
    static const char digits[] = "0123456789ABCDEF";
    for (int shift = 28; shift >= 0; shift -= 4)
        uart_putc(digits[(value >> shift) & 0x0fu]);
}

[[noreturn]] void fail(const char* stage, u32 address, u32 expected, u32 actual)
{
    uart_puts("FAIL ");
    uart_puts(stage);
    uart_puts(" addr="); uart_hex(address);
    uart_puts(" expected="); uart_hex(expected);
    uart_puts(" actual="); uart_hex(actual);
    uart_puts("\r\n");
    for (;;)
        __asm__ volatile ("" ::: "memory");
}

void check(const char* stage, u32 address, u32 expected)
{
    const u32 actual = word(address);
    if (actual != expected)
        fail(stage, address, expected, actual);
}

void pass(const char* stage)
{
    uart_puts("PASS ");
    uart_puts(stage);
    uart_puts("\r\n");
}

u32 lfsr_next(u32 value)
{
    const u32 lsb = value & 1u;
    value >>= 1;
    if (lsb != 0u)
        value ^= 0x80200003u;
    return value;
}

void wait_for_mig()
{
    uart_puts("Waiting for MIG calibration...\r\n");
    u32 status = 0u;
    for (u32 timeout = 0u; timeout < 100000000u; ++timeout) {
        status = DDR_STATUS;
        if ((status & DDR_STATUS_CALIB_ERROR) != 0u)
            fail("MIG_CALIB", SOC_DDR_CTRL_BASE, 0u, status);
        if ((status & DDR_STATUS_CALIB_DONE) != 0u) {
            if ((status & DDR_STATUS_EXTERNAL_MIG) == 0u)
                fail("MIG_SELECT", SOC_DDR_CTRL_BASE,
                     DDR_STATUS_EXTERNAL_MIG, status);
            pass("MIG calibration");
            return;
        }
    }
    fail("MIG_TIMEOUT", SOC_DDR_CTRL_BASE,
         DDR_STATUS_CALIB_DONE, status);
}

void test_data_bus()
{
    const u32 address = DDR_BASE + 0x1000u;
    for (u32 bit = 0u; bit < 32u; ++bit) {
        const u32 pattern = 1u << bit;
        word(address) = pattern;
        check("DATA_ONE", address, pattern);
        word(address) = ~pattern;
        check("DATA_ZERO", address, ~pattern);
    }
    pass("32-bit data bus walking ones/zeros");
}

void test_narrow_and_wstrb()
{
    const u32 address = DDR_BASE + 0x2000u;
    word(address) = 0u;
    byte(address + 0u) = 0x11u;
    byte(address + 1u) = 0x22u;
    byte(address + 2u) = 0x33u;
    byte(address + 3u) = 0x44u;
    check("BYTE_WSTRB", address, 0x44332211u);

    half(address + 0u) = 0xa55au;
    half(address + 2u) = 0x3cc3u;
    check("HALF_WSTRB", address, 0x3cc3a55au);
    if (byte(address + 1u) != 0xa5u || half(address + 2u) != 0x3cc3u)
        fail("NARROW_READ", address, 0x3cc3a55au, word(address));
    pass("byte/halfword narrow access and WSTRB");
}

void test_address_bus()
{
    const u32 anchor = DDR_BASE + 0x4000u;
    word(anchor) = 0x5aa55aa5u;
    for (u32 bit = 2u; bit < 30u; ++bit)
        word(anchor + (1u << bit)) = 0xa5000000u | bit;

    check("ADDR_ANCHOR", anchor, 0x5aa55aa5u);
    for (u32 bit = 2u; bit < 30u; ++bit)
        check("ADDR_LINE", anchor + (1u << bit), 0xa5000000u | bit);
    pass("DDR address lines across 1-GiB aperture");
}

void test_checkerboard()
{
    const u32 base = DDR_BASE + 0x00100000u;
    for (u32 i = 0u; i < TEST_WORDS; ++i)
        word(base + (i << 2)) = (i & 1u) ? 0x55555555u : 0xaaaaaaaau;
    for (u32 i = 0u; i < TEST_WORDS; ++i)
        check("CHECKER", base + (i << 2),
              (i & 1u) ? 0x55555555u : 0xaaaaaaaau);
    pass("64-KiB checkerboard");
}

void test_pseudorandom()
{
    const u32 base = DDR_BASE + 0x00110000u;
    u32 state = 0x1aceb00cu;
    for (u32 i = 0u; i < TEST_WORDS; ++i) {
        state = lfsr_next(state);
        word(base + (i << 2)) = state;
    }
    state = 0x1aceb00cu;
    for (u32 i = 0u; i < TEST_WORDS; ++i) {
        state = lfsr_next(state);
        check("LFSR", base + (i << 2), state);
    }
    pass("64-KiB deterministic pseudo-random pattern");
}

void program_iommu_page(u32 index, u32 vpn, u32 ppn)
{
    IOMMU_PT_INDEX = index;
    IOMMU_PT_VPN = vpn;
    IOMMU_PT_PPN = ppn;
    IOMMU_PT_FLAGS = 7u; // valid + readable + writable; commits the entry.
}

void dma_copy(u32 source, u32 destination, u32 length)
{
    DMA_CONTROL = 2u;
    DMA_SRC_VADDR = source;
    DMA_DST_VADDR = destination;
    DMA_LENGTH_BYTES = length;
    DMA_CONFIG = (16u << 8) | (DMA_MODE_BURST << 2) | DMA_TYPE_M2M;
    DMA_CONTROL = 1u;
    for (u32 timeout = 0u; timeout < 100000000u; ++timeout) {
        const u32 status = DMA_STATUS;
        if ((status & DMA_STATUS_FAULT) != 0u)
            fail("DMA_FAULT", SOC_DMA_BASE, 0u, DMA_FAULT);
        if ((status & DMA_STATUS_DONE) != 0u)
            return;
    }
    fail("DMA_TIMEOUT", SOC_DMA_BASE, DMA_STATUS_DONE, DMA_STATUS);
}

void test_dma_iommu()
{
    constexpr u32 VIRT_BRAM_SRC = 0x01000000u;
    constexpr u32 VIRT_DDR = 0x01001000u;
    constexpr u32 VIRT_BRAM_DST = 0x01002000u;

    program_iommu_page(0u, VIRT_BRAM_SRC >> 12, BRAM_DMA_SRC >> 12);
    program_iommu_page(1u, VIRT_DDR >> 12, DDR_DMA_AREA >> 12);
    program_iommu_page(2u, VIRT_BRAM_DST >> 12, BRAM_DMA_DST >> 12);
    IOMMU_TLB_CTRL = 1u;
    DMA_ACCESS_CTRL = 0u;

    for (u32 i = 0u; i < DMA_BYTES / 4u; ++i) {
        word(BRAM_DMA_SRC + (i << 2)) = 0xd00d0000u | i;
        word(BRAM_DMA_DST + (i << 2)) = 0u;
        word(DDR_DMA_AREA + (i << 2)) = 0u;
    }

    dma_copy(VIRT_BRAM_SRC, VIRT_DDR, DMA_BYTES);
    for (u32 i = 0u; i < DMA_BYTES / 4u; ++i)
        check("DMA_BRAM_DDR", DDR_DMA_AREA + (i << 2), 0xd00d0000u | i);

    dma_copy(VIRT_DDR, VIRT_BRAM_DST, DMA_BYTES);
    for (u32 i = 0u; i < DMA_BYTES / 4u; ++i)
        check("DMA_DDR_BRAM", BRAM_DMA_DST + (i << 2), 0xd00d0000u | i);
    pass("DMA/IOMMU BRAM->DDR3->BRAM");
}

} // namespace

extern "C" [[noreturn]] void firmware_main()
{
    UART_DIVIDER = SOC_UART_DIVIDER;
    uart_puts("\r\nVC707 DDR3 SELF-TEST START\r\n");
    wait_for_mig();
    test_data_bus();
    test_narrow_and_wstrb();
    test_address_bus();
    test_checkerboard();
    test_pseudorandom();
    test_dma_iommu();
    uart_puts("ALL VC707 DDR3 TESTS PASSED\r\n");
    for (;;)
        __asm__ volatile ("" ::: "memory");
}

extern "C" [[gnu::naked, gnu::used, gnu::section(".text.start"), noreturn]]
void _start()
{
    __asm__ volatile (
        "li sp, 0x10000\n"
        "j firmware_main\n"
    );
}
