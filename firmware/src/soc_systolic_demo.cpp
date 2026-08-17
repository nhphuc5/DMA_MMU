/* PicoRV32 + 4x4 systolic-array hardware demonstration.
 *
 * Firmware writes two signed INT8 matrices through AXI4-Lite, starts the
 * accelerator, waits for DONE, reads all sixteen signed INT32 results, and
 * compares them with an independently precomputed reference matrix.  The
 * visible UART result is therefore based on values read back from hardware.
 */

#include "soc_map.h"

using u32 = unsigned int;
using s32 = signed int;

#ifndef SOC_UART_DIVIDER
#define SOC_UART_DIVIDER 4u
#endif

namespace {

constexpr u32 pack4(unsigned a, unsigned b, unsigned c, unsigned d)
{
    return (a & 0xffu) | ((b & 0xffu) << 8)
         | ((c & 0xffu) << 16) | ((d & 0xffu) << 24);
}

constexpr u32 MATRIX_A[4] = {
    pack4( 1,  2, 3, 4),
    pack4(-1,  0, 2, 1),
    pack4( 5, -2, 1, 0),
    pack4( 3,  3, 3, 3)
};

constexpr u32 MATRIX_B[4] = {
    pack4( 1,  0, 2, -1),
    pack4( 2,  1, 0,  3),
    pack4(-1,  4, 1,  0),
    pack4( 3, -2, 2,  1)
};

constexpr s32 EXPECTED_C[16] = {
    14, 6, 13, 9,
     0, 6,  2, 2,
     0, 2, 11,-11,
    15, 9, 15, 9
};

inline void uart_putc(char value)
{
    UART_DATA = static_cast<u32>(static_cast<unsigned char>(value));
}

void uart_text(const char* text)
{
    while (*text != '\0')
        uart_putc(*text++);
}

void uart_hex32(u32 value)
{
    static constexpr char HEX[] = "0123456789ABCDEF";
    for (int shift = 28; shift >= 0; shift -= 4)
        uart_putc(HEX[(value >> static_cast<unsigned>(shift)) & 0x0fu]);
}

[[noreturn]] void halt()
{
    for (;;)
        __asm__ volatile ("" ::: "memory");
}

[[noreturn]] void demo_main()
{
    UART_DIVIDER = SOC_UART_DIVIDER;
    UART_CONTROL = 3u;
    uart_text("SYSTOLIC 4X4 START\r\n");

    if (SYSTOLIC_ID != 0x53595354u) {
        uart_text("SYSTOLIC ID FAIL\r\n");
        halt();
    }

    SYSTOLIC_CONTROL = SYSTOLIC_CLEAR_DONE;
    for (u32 row = 0; row < 4u; ++row) {
        SYSTOLIC_A_ROW(row) = MATRIX_A[row];
        SYSTOLIC_B_ROW(row) = MATRIX_B[row];
    }

    SYSTOLIC_CONTROL = SYSTOLIC_START;
    while ((SYSTOLIC_STATUS & SYSTOLIC_DONE) == 0u) {
    }

    u32 errors = 0u;
    for (u32 element = 0; element < 16u; ++element) {
        const s32 actual = static_cast<s32>(SYSTOLIC_C_ELEM(element));
        if (actual != EXPECTED_C[element])
            ++errors;
        uart_hex32(static_cast<u32>(actual));
        uart_putc((element & 3u) == 3u ? '\n' : ' ');
    }

    uart_text("CYCLES=0x");
    uart_hex32(SYSTOLIC_CYCLES);
    uart_text("\r\n");
    if (errors == 0u)
        uart_text("SYSTOLIC PASS\r\n");
    else
        uart_text("SYSTOLIC FAIL\r\n");
    halt();
}

} // namespace

extern "C" [[noreturn, gnu::naked, gnu::section(".text.start")]] void _start()
{
    __asm__ volatile (
        "li sp, 0x10000\n"
        "j systolic_demo_entry\n"
    );
}

extern "C" [[noreturn]] void systolic_demo_entry()
{
    demo_main();
}
