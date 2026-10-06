/* link.ld - bare-metal RV32I memory map
   IMEM (code) at 0x0000_0000, DMEM (data) at 0x1000_0000 */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
  IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
  DMEM (rw)  : ORIGIN = 0x10000000, LENGTH = 16K
}
SECTIONS {
  .text : {
    *(.text.init)      /* _start first */
    *(.text*)
  } > IMEM
  .rodata : { *(.rodata*) } > IMEM
  .data : { *(.data*) }   > DMEM
  .bss  : { *(.bss*) *(COMMON) } > DMEM
  /* _end marks top of used data */
  _end = .;
}
