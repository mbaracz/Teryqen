/* Kernel linked in the top 2 GiB. It's a PIE, Limine relocates it.
 * Separate segments so code isn't writable and data isn't executable. */
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

PHDRS
{
    text    PT_LOAD    FLAGS(5); /* r-x */
    rodata  PT_LOAD    FLAGS(4); /* r-- */
    data    PT_LOAD    FLAGS(6); /* rw- */
    dynamic PT_DYNAMIC FLAGS(4);
}

SECTIONS
{
    . = 0xffffffff80000000;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    /* relocation stuff, Limine needs it */
    .dynsym       : { *(.dynsym) }                     :rodata
    .dynstr       : { *(.dynstr) }                     :rodata
    .hash         : { *(.hash) }                       :rodata
    .gnu.hash     : { *(.gnu.hash) }                   :rodata
    .rela.dyn     : { *(.rela.dyn .rela.*) }           :rodata
    .dynamic      : { *(.dynamic) }                    :rodata :dynamic
    .data.rel.ro  : { *(.data.rel.ro .data.rel.ro.*) } :rodata
    .got          : { *(.got) *(.got.plt) }            :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    /* Limine requests, markers must stay around them in this order */
    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :data

    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.interp)
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
    }
}
