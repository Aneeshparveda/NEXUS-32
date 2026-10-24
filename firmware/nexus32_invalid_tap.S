    .option norvc
    .equ    POLL_TIMEOUT, 100000
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lui     sp, 0x14
    lui     s2, 0x10               # DMEM base 0x00010000
    li      s4, 0
    li      t0, 0x4e583332         # "NX32" boot signature
    sw      t0, 0(s2)

    lui     s3, 0x10005            # accelerator CSR base 0x10005000
    li      t0, 0                  # invalid TAP_COUNT
    sw      t0, 8(s3)
    lui     t0, 0x20
    sw      t0, 12(s3)             # COEFF_PTR
    lui     t0, 0x21
    sw      t0, 16(s3)             # INPUT_PTR
    lui     t0, 0x22
    sw      t0, 20(s3)             # OUTPUT_PTR
    li      t0, 1
    sw      t0, 28(s3)             # SAMPLE_COUNT
    li      t0, 6
    sw      t0, 4(s3)              # clear stale DONE/ERROR while idle
    li      t0, 1
    sw      t0, 0(s3)              # CTRL.START

    li      t5, POLL_TIMEOUT
poll_status:
    lw      t1, 4(s3)              # STATUS
    mv      s4, t1
    andi    t2, t1, 4              # ERROR first
    bne     t2, zero, fail_error
    andi    t2, t1, 2              # DONE without ERROR is unexpected here
    bne     t2, zero, fail_result
    addi    t5, t5, -1
    beq     t5, zero, fail_timeout
    jal     zero, poll_status

fail_result:
    li      t2, 1
    sw      t2, 24(s2)              # DMEM[6]: failure cause
    sw      s4, 28(s2)              # DMEM[7]: last STATUS snapshot
    jal     zero, fail

fail_error:
    li      t2, 2
    sw      t2, 24(s2)
    sw      t1, 28(s2)
    jal     zero, fail

fail_timeout:
    li      t2, 3
    sw      t2, 24(s2)
    sw      t1, 28(s2)

fail:
    li      t2, 0xdead0001
    sw      t2, 8(s2)
    sw      t1, 4(s2)
fail_halt:
    jal     zero, fail_halt
