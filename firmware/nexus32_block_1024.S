    .option norvc
    .equ    POLL_TIMEOUT, 2000000
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lui     sp, 0x14
    lui     s2, 0x10               # DMEM base 0x00010000
    li      s4, 0                  # last STATUS snapshot
    li      t0, 0x4e583332         # "NX32" boot signature
    sw      t0, 0(s2)

    # Deterministic 1024-sample block: every sample is +1.0 Q16.16.
    # Coefficients [0.5, 0.25, 0.25] produce representative outputs
    # [0.5, 0.75, 1.0, 1.0, ...] with zero history at the block boundary.
    lui     s0, 0x20               # coefficient base 0x00020000
    lui     s1, 0x21               # sample base 0x00021000
    li      t0, 32768
    sw      t0, 0(s0)
    li      t0, 16384
    sw      t0, 4(s0)
    sw      t0, 8(s0)

    li      t0, 1024
    li      t1, 65536
write_samples:
    sw      t1, 0(s1)
    addi    s1, s1, 4
    addi    t0, t0, -1
    bne     t0, zero, write_samples

    lui     s3, 0x10005            # accelerator CSR base 0x10005000
    li      t0, 3
    sw      t0, 8(s3)              # TAP_COUNT=3
    lui     t0, 0x20
    sw      t0, 12(s3)             # COEFF_PTR
    lui     t0, 0x21
    sw      t0, 16(s3)             # INPUT_PTR
    lui     t0, 0x22
    sw      t0, 20(s3)             # OUTPUT_PTR
    li      t0, 1024
    sw      t0, 28(s3)             # SAMPLE_COUNT=1024
    li      t0, 6
    sw      t0, 4(s3)              # clear sticky DONE and recoverable ERROR
    li      t0, 1
    sw      t0, 0(s3)              # CTRL.START, sequential architecture

    li      t5, POLL_TIMEOUT
poll_status:
    lw      t1, 4(s3)              # STATUS
    mv      s4, t1
    andi    t2, t1, 4              # ERROR first
    bne     t2, zero, fail_error
    andi    t2, t1, 2              # DONE
    bne     t2, zero, completed
    addi    t5, t5, -1
    beq     t5, zero, fail_timeout
    jal     zero, poll_status

completed:
    li      t2, 2
    bne     t1, t2, fail_status
    lw      t1, 60(s3)             # RESULT_COUNT
    sw      t1, 32(s2)             # DMEM[8]: result-count observation
    li      t2, 1024
    bne     t1, t2, fail_result_count

    lui     t0, 0x22               # result base 0x00022000
    lw      t1, 0(t0)
    sw      t1, 4(s2)              # DMEM[1]: result[0]
    li      t2, 32768              # 0.5 Q16.16
    bne     t1, t2, fail_result

    lw      t1, 4(t0)
    sw      t1, 12(s2)             # DMEM[3]: result[1]
    li      t2, 49152              # 0.75 Q16.16
    bne     t1, t2, fail_result

    lw      t1, 8(t0)
    sw      t1, 16(s2)             # DMEM[4]: result[2]
    li      t2, 65536              # 1.0 Q16.16
    bne     t1, t2, fail_result

    li      t2, 4092
    add     t0, t0, t2
    lw      t1, 0(t0)              # result[1023]
    sw      t1, 20(s2)             # DMEM[5]: final result observation
    li      t2, 65536
    bne     t1, t2, fail_result

    sw      s4, 36(s2)             # DMEM[9]: terminal STATUS snapshot
    li      t0, 0x600d600d         # PASS sentinel
    sw      t0, 8(s2)
pass_halt:
    jal     zero, pass_halt

fail_status:
    li      t2, 4                  # terminal STATUS was not exactly DONE-only
    jal     zero, fail
fail_result_count:
    li      t2, 5                  # RESULT_COUNT mismatch
    jal     zero, fail
fail_result:
    li      t2, 1                  # representative result mismatch
    jal     zero, fail
fail_error:
    li      t2, 2                  # accelerator ERROR
    jal     zero, fail
fail_timeout:
    li      t2, 3                  # bounded poll timeout

fail:
    sw      t2, 24(s2)             # DMEM[6]: failure cause
    sw      s4, 28(s2)             # DMEM[7]: STATUS snapshot
    li      t0, 0xdead0001
    sw      t0, 8(s2)
fail_halt:
    jal     zero, fail_halt
