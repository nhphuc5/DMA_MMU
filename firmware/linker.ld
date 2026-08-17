OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    . = ORIGIN(RAM);

    .text : ALIGN(4)
    {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > RAM

    .data : ALIGN(4)
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : ALIGN(4)
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

    /* VA 0x8000 is deliberately translated to PA 0x3000 by the CPU MMU
     * regression.  Keep firmware below that physical scratch page. */
    ASSERT(__image_end <= 0x3000,
           "Firmware overlaps physical page 0x3000 used by CPU-MMU test")
}
