    .option norvc
    .equ    POLL_TIMEOUT, 100000
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lui     sp, 0x14
    lui     s2, 0x10               # DMEM base 0x00010000
    li      s4, 0                  # last STATUS snapshot for diagnostics
    li      t0, 0x4e583332         # "NX32" boot signature
    sw      t0, 0(s2)

    # Load the four-tap fixed-point vector through the CPU bus.
    lui     s0, 0x20               # coefficient base 0x00020000
    lui     s1, 0x21               # sample base 0x00021000

    li      t0, 65536              # +1.0 Q16.16
    sw      t0, 0(s0)
    li      t0, 32768              # +0.5 Q16.16
    sw      t0, 4(s0)
    li      t0, -32768             # -0.5 Q16.16
    sw      t0, 8(s0)
    li      t0, 65536              # +1.0 Q16.16
    sw      t0, 12(s0)

    li      t0, 131072             # +2.0 Q16.16
    sw      t0, 0(s1)
    li      t0, 262144             # +4.0 Q16.16
    sw      t0, 4(s1)
    li      t0, 131072             # +2.0 Q16.16
    sw      t0, 8(s1)
    li      t0, -65536             # -1.0 Q16.16
    sw      t0, 12(s1)

    lui     s3, 0x10005            # accelerator CSR base 0x10005000
    li      t0, 4
    sw      t0, 8(s3)              # TAP_COUNT
    lui     t0, 0x20
    sw      t0, 12(s3)             # COEFF_PTR
    lui     t0, 0x21
    sw      t0, 16(s3)             # INPUT_PTR
    lui     t0, 0x22
    sw      t0, 20(s3)             # OUTPUT_PTR
    li      t0, 1
    sw      t0, 28(s3)             # SAMPLE_COUNT: one legacy window
    li      t0, 6
    sw      t0, 4(s3)              # clear sticky DONE and recoverable ERROR
    li      t0, 1
    sw      t0, 0(s3)              # CTRL.START

    li      t5, POLL_TIMEOUT
poll_status:
    lw      t1, 4(s3)              # STATUS
    mv      s4, t1
    andi    t2, t1, 4              # ERROR sticky bit; check before DONE
    bne     t2, zero, fail_error
    andi    t2, t1, 2              # DONE sticky bit
    bne     t2, zero, completed
    addi    t5, t5, -1
    beq     t5, zero, fail_timeout
    jal     zero, poll_status

completed:
    lui     t0, 0x22               # result at 0x00022000
    lw      t1, 0(t0)
    li      t2, 131072             # expected 2.0 Q16.16
    bne     t1, t2, fail_result

    sw      t1, 4(s2)              # result signature for testbench
    li      t2, 0x600d600d         # PASS sentinel
    sw      t2, 8(s2)
pass_halt:
    jal     zero, pass_halt

fail_result:
    li      t2, 1                  # result mismatch
    sw      t2, 24(s2)             # DMEM[6]: failure cause
    sw      s4, 28(s2)             # DMEM[7]: last STATUS snapshot
    jal     zero, fail

fail_error:
    li      t2, 2                  # accelerator ERROR
    sw      t2, 24(s2)
    sw      t1, 28(s2)
    jal     zero, fail

fail_timeout:
    li      t2, 3                  # bounded poll timeout
    sw      t2, 24(s2)
    sw      t1, 28(s2)

fail:
    li      t2, 0xdead0001
    sw      t2, 8(s2)
    sw      t1, 4(s2)
fail_halt:
    jal     zero, fail_halt
