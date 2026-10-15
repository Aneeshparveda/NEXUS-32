.section .text.init
.globl _start
_start:
    # Form 0x10000000 and attempt to fetch an instruction from MMIO space.
    # The SoC must reject the fetch locally and must not issue an accelerator
    # bus request for it.
    lui   t0, 0x10000
    jalr  zero, 0(t0)
1:
    jal   zero, 1b
