    .option norvc
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lui     sp, 0x14
    lui     s2, 0x10               # DMEM base 0x00010000
    li      t0, 0x4e583332         # "NX32" boot signature
    sw      t0, 0(s2)

    # Use only word-aligned DMEM addresses.  The access width still selects
    # the CPU byte strobes: SB writes byte 0 and SH writes halfword 0.
    addi    s0, s2, 32              # DMEM[8], aligned sub-word fixture base
    li      t0, 0x00000080
    sb      t0, 0(s0)               # signed-negative byte
    li      t0, 0x00008001
    sh      t0, 4(s0)               # signed-negative halfword
    li      t0, 0x0000007f
    sb      t0, 8(s0)               # signed-positive byte
    li      t0, 0x00007fff
    sh      t0, 12(s0)              # signed-positive halfword

    # Signed and unsigned byte loads from the negative fixture.
    lb      t0, 0(s0)
    sw      t0, 12(s2)              # DMEM[3]: LB observed value
    li      t1, -128
    bne     t0, t1, fail_lb

    lbu     t0, 0(s0)
    sw      t0, 16(s2)              # DMEM[4]: LBU observed value
    li      t1, 128
    bne     t0, t1, fail_lbu

    # Signed and unsigned halfword loads from the negative fixture.
    lh      t0, 4(s0)
    sw      t0, 20(s2)              # DMEM[5]: LH observed value
    li      t1, -32767
    bne     t0, t1, fail_lh

    lhu     t0, 4(s0)
    sw      t0, 32(s2)              # DMEM[8]: LHU negative observed value
    li      t1, 32769
    bne     t0, t1, fail_lhu

    # Exercise the positive signed/unsigned cases as well.
    lbu     t0, 8(s0)
    sw      t0, 36(s2)              # DMEM[9]: LBU positive observed value
    li      t1, 127
    bne     t0, t1, fail_lbu_positive

    lh      t0, 12(s0)
    sw      t0, 40(s2)              # DMEM[10]: LH positive observed value
    li      t1, 32767
    bne     t0, t1, fail_lh_positive

    lhu     t0, 12(s0)
    sw      t0, 44(s2)              # DMEM[11]: LHU positive observed value
    li      t1, 32767
    bne     t0, t1, fail_lhu_positive

    li      t0, 0x600d600d         # PASS sentinel
    sw      t0, 8(s2)
pass_halt:
    jal     zero, pass_halt

fail_lb:
    li      t0, 1
    jal     zero, fail
fail_lbu:
    li      t0, 2
    jal     zero, fail
fail_lh:
    li      t0, 3
    jal     zero, fail
fail_lhu:
    li      t0, 4
    jal     zero, fail
fail_lbu_positive:
    li      t0, 5
    jal     zero, fail
fail_lh_positive:
    li      t0, 6
    jal     zero, fail
fail_lhu_positive:
    li      t0, 7

fail:
    sw      t0, 24(s2)              # DMEM[6]: failure cause
    sw      zero, 28(s2)            # DMEM[7]: no accelerator status
    li      t0, 0xdead0001
    sw      t0, 8(s2)
fail_halt:
    jal     zero, fail_halt
