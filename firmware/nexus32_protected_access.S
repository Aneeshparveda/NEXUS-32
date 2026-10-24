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

    # Fill both accelerator banks with 1.0 Q16.16 values.  A 32-tap run is
    # long enough that the CPU can issue protected accesses while BUSY=1.
    lui     s0, 0x20               # coefficient base 0x00020000
    lui     s1, 0x21               # sample base 0x00021000
    li      t0, 32
    li      t1, 65536
fill_banks:
    sw      t1, 0(s0)
    sw      t1, 0(s1)
    addi    s0, s0, 4
    addi    s1, s1, 4
    addi    t0, t0, -1
    bne     t0, zero, fill_banks

    lui     s0, 0x20
    lui     s1, 0x21
    lui     s3, 0x10005            # accelerator CSR base 0x10005000
    li      t0, 32
    sw      t0, 8(s3)              # TAP_COUNT
    lui     t0, 0x20
    sw      t0, 12(s3)             # COEFF_PTR
    lui     t0, 0x21
    sw      t0, 16(s3)             # INPUT_PTR
    lui     t0, 0x22
    sw      t0, 20(s3)             # OUTPUT_PTR
    li      t0, 1
    sw      t0, 28(s3)             # SAMPLE_COUNT
    li      t0, 6
    sw      t0, 4(s3)              # clear sticky DONE and recoverable ERROR
    li      t0, 1
    sw      t0, 0(s3)              # CTRL.START, sequential architecture

    # A status read confirms the protected accesses occur during ownership,
    # rather than relying on a guessed delay after START.
    lw      t1, 4(s3)              # STATUS
    mv      s4, t1
    andi    t2, t1, 1              # BUSY
    beq     t2, zero, fail_result

    # Protected sample reads return the documented sentinel through the CPU
    # bridge. PicoRV32 has no native error input, so firmware checks the data.
    lui     t0, 0x21
    lw      t1, 0(t0)
    li      t2, 0xbad00001
    bne     t1, t2, fail_result
    sw      t1, 12(s2)             # DMEM[3]: protected-read sentinel

    # Check BUSY again immediately before a rejected result-memory write.
    lw      t3, 4(s3)
    mv      s4, t3
    andi    t4, t3, 1
    beq     t4, zero, fail_result
    lui     t0, 0x22
    li      t1, 0xdeadbeef
    sw      t1, 0(t0)              # forbidden host result write

    li      t5, POLL_TIMEOUT
poll_status:
    lw      t1, 4(s3)              # STATUS
    mv      s4, t1
    andi    t2, t1, 4              # ERROR; check before DONE
    bne     t2, zero, fail_error
    andi    t2, t1, 2              # DONE
    bne     t2, zero, completed
    addi    t5, t5, -1
    beq     t5, zero, fail_timeout
    jal     zero, poll_status

completed:
    # The two host failures are software-readable through DBG_STATUS.
    lw      t1, 48(s3)             # DBG_STATUS
    andi    t2, t1, 12             # MEM_OWNERSHIP | RESULT_WRITE_FORBIDDEN
    li      t3, 12
    bne     t2, t3, fail_result
    sw      t1, 16(s2)             # DMEM[4]: debug status snapshot

    lui     t0, 0x22
    lw      t1, 0(t0)              # committed result
    li      t2, 65536              # 1.0 Q16.16; zero history at block start
    bne     t1, t2, fail_result
    sw      t1, 4(s2)              # DMEM[1]: result signature

    lw      t1, 60(s3)             # RESULT_COUNT
    li      t2, 1
    bne     t1, t2, fail_result
    sw      t1, 20(s2)             # DMEM[5]: commit-count signature

    li      t2, 0x600d600d         # PASS sentinel
    sw      t2, 8(s2)
pass_halt:
    jal     zero, pass_halt

fail_result:
    li      t2, 1                  # result/status validation mismatch
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
