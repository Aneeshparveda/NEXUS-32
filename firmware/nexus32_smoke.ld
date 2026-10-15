OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
}
SECTIONS
{
    . = ORIGIN(IMEM);
    .text : ALIGN(4)
    {
        KEEP(*(.text.init))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > IMEM
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
