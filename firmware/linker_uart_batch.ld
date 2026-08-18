OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}
SECTIONS
{
    . = ORIGIN(RAM);

    /* Keep executable/constant contents in virtual page 0. */
    .text : ALIGN(4)
    {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > RAM

    ASSERT(. <= 0x1000, "UART batch firmware text exceeds RX page 0")

    /* Put mutable C/C++ state in virtual page 1.  The firmware maps this
     * page RW (not executable), so FrameInfo and DMA diagnostics are not
     * silently rejected by the CPU-side MMU. */
    .data 0x1000 : ALIGN(4)
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    .bss MAX(ADDR(.data) + SIZEOF(.data), 0x1000) (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    __image_end = ALIGN(16);
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }

    ASSERT(__image_end <= 0x3000,
           "Firmware overlaps physical page 0x3000 used by CPU-MMU test")
}
