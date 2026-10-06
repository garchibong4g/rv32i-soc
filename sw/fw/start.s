# start.s - bare-metal RV32I startup
# Sets the stack pointer, calls main(), then spins on return (or HLT).
    .section .text.init
    .globl _start
_start:
    # stack pointer to top of DMEM region (0x1000_0000 + 0x0FF0, below the
    # result mailbox at 0x0FFC). DMEM base goes in the upper immediate.
    lui   sp, 0x10000        # sp = 0x1000_0000
    addi  sp, sp, 0x0F0      # sp = 0x1000_00F0 (small stack, grows down)
    # actually place stack high in the 4KB page:
    lui   sp, 0x10000
    addi  sp, sp, 0x7F0      # sp = 0x1000_07F0

    call  main
1:  j     1b                 # park on return
