/*
 * NEXUS-32 board demo firmware (bare-metal RV32I, no M extension).
 *
 * 1. Reads SYS_INFO for the build's LANES and clock; uses TAP_COUNT = LANES.
 * 2. Writes 32 coefficients and a 1024-sample block generated on the CPU with
 *    the recurrence in scripts/gen_demo_expected.py.
 * 3. Runs the block on the sequential, parallel and pipelined engines
 *    (ARCH_SEL 0/1/2), recording STATUS, CYCLES_TOTAL, COMPUTE_CYCLES and
 *    RESULT_COUNT, and a rolling checksum of the 1024 result words.
 * 4. An architecture passes when STATUS == DONE only, RESULT_COUNT == 1024 and
 *    the checksum equals the constant derived from the Python golden model.
 * 5. Writes the boot/PASS (or FAIL) DMEM signatures used by the board LEDs,
 *    then prints the report over the UART (115200 8N1) and re-prints it about
 *    every 1.6 s, so a terminal opened late still shows it.
 *
 * DMEM map: [0] boot signature, [1] overall fail flag, [2] PASS/FAIL
 * signature, [3] SYS_INFO, 0x100.. per-architecture records of 6 words:
 * STATUS, CYCLES_TOTAL, COMPUTE_CYCLES, RESULT_COUNT, checksum, pass flag.
 */
#include "nexus32_demo_expected.inc"

    .option norvc
    .equ    POLL_TIMEOUT, 1000000
    .equ    RECORD_WORDS, 6
    .equ    RECORD_BYTES, 24
    .equ    TABLE_OFFSET, 0x100

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lui     sp, 0x14               # stack top = end of DMEM (0x00014000)
    lui     s2, 0x10               # DMEM base 0x00010000
    li      t0, 0x4e583332         # "NX32" boot signature
    sw      t0, 0(s2)
    lui     s3, 0x10005            # accelerator CSR base 0x10005000
    lui     s5, 0x10006            # system page base 0x10006000

    lw      s6, 8(s5)              # SYS_INFO: [7:0] LANES, [15:8] CLK_MHZ
    sw      s6, 12(s2)
    andi    s7, s6, 0xff           # TAP_COUNT = LANES

    # Golden checksum for this TAP_COUNT; an unknown build cannot match.
    li      s8, 0xffffffff
    li      t0, 4
    bne     s7, t0, 1f
    li      s8, EXPECT_CHK_T4
1:  li      t0, 8
    bne     s7, t0, 1f
    li      s8, EXPECT_CHK_T8
1:  li      t0, 16
    bne     s7, t0, 1f
    li      s8, EXPECT_CHK_T16
1:  li      t0, 32
    bne     s7, t0, 1f
    li      s8, EXPECT_CHK_T32
1:

    # Coefficients: c[k] = COEFF0 - k*COEFF_STEP, k = 0..31.
    lui     s0, 0x20               # coefficient base 0x00020000
    li      t0, DEMO_COEFF0
    li      t1, DEMO_COEFF_STEP
    li      t2, DEMO_COEFF_WORDS
write_coefficients:
    sw      t0, 0(s0)
    sub     t0, t0, t1
    addi    s0, s0, 4
    addi    t2, t2, -1
    bne     t2, zero, write_coefficients

    # Samples: s = s*5 + STEP; sample = int32(s) >> 12 (arithmetic).
    lui     s1, 0x21               # sample base 0x00021000
    li      t0, DEMO_SEED
    li      t3, DEMO_STEP
    li      t2, DEMO_SAMPLES
write_samples:
    slli    t1, t0, 2
    add     t0, t0, t1
    add     t0, t0, t3
    srai    t1, t0, 12
    sw      t1, 0(s1)
    addi    s1, s1, 4
    addi    t2, t2, -1
    bne     t2, zero, write_samples

    # Configuration shared by all three runs.
    sw      s7, 8(s3)              # TAP_COUNT
    lui     t0, 0x20
    sw      t0, 12(s3)             # COEFF_PTR
    lui     t0, 0x21
    sw      t0, 16(s3)             # INPUT_PTR
    lui     t0, 0x22
    sw      t0, 20(s3)             # OUTPUT_PTR
    li      t0, DEMO_SAMPLES
    sw      t0, 28(s3)             # SAMPLE_COUNT

    li      s9, 0                  # architecture index 0..2
    li      s10, 0                 # overall fail flag
    addi    s11, s2, TABLE_OFFSET  # record pointer

run_architecture:
    li      t0, 6
    sw      t0, 4(s3)              # W1C sticky DONE and recoverable ERROR
    slli    t0, s9, 2
    ori     t0, t0, 1
    sw      t0, 0(s3)              # CTRL: START | ARCH_SEL

    li      t5, POLL_TIMEOUT
poll_status:
    lw      t1, 4(s3)              # STATUS
    andi    t2, t1, 6              # DONE or ERROR ends the run
    bne     t2, zero, run_finished
    addi    t5, t5, -1
    bne     t5, zero, poll_status
run_finished:
    sw      t1, 0(s11)             # STATUS snapshot
    lw      t0, 0x18(s3)
    sw      t0, 4(s11)             # CYCLES_TOTAL
    lw      t0, 0x20(s3)
    sw      t0, 8(s11)             # COMPUTE_CYCLES
    lw      t0, 0x3c(s3)
    sw      t0, 12(s11)            # RESULT_COUNT

    # Rolling checksum over the 1024 result words.
    lui     t3, 0x22               # result base 0x00022000
    li      t2, DEMO_SAMPLES
    li      t4, 0
checksum_results:
    lw      t0, 0(t3)
    slli    t1, t4, 5
    srli    t4, t4, 27
    or      t4, t4, t1
    xor     t4, t4, t0
    addi    t3, t3, 4
    addi    t2, t2, -1
    bne     t2, zero, checksum_results
    sw      t4, 16(s11)

    # Pass: STATUS == DONE only, RESULT_COUNT == 1024, checksum == golden.
    li      t0, 1
    lw      t1, 0(s11)
    li      t2, 2
    beq     t1, t2, 1f
    li      t0, 0
1:  lw      t1, 12(s11)
    li      t2, DEMO_SAMPLES
    beq     t1, t2, 1f
    li      t0, 0
1:  beq     t4, s8, 1f
    li      t0, 0
1:  sw      t0, 20(s11)
    bne     t0, zero, 1f
    li      s10, 1
1:
    addi    s11, s11, RECORD_BYTES
    addi    s9, s9, 1
    li      t0, 3
    blt     s9, t0, run_architecture

    # Board-visible verdict (LED2 PASS, LED3 untouched by firmware).
    sw      s10, 4(s2)
    li      t0, 0x600d600d
    beq     s10, zero, 1f
    li      t0, 0xdead0001
1:  sw      t0, 8(s2)

report_forever:
    jal     ra, print_report
    srli    t0, s6, 8
    andi    t0, t0, 0xff           # CLK_MHZ
    slli    t0, t0, 17             # ~1.6 s of delay-loop iterations
delay_loop:
    addi    t0, t0, -1
    bne     t0, zero, delay_loop
    jal     zero, report_forever

/* ---------------------------------------------------------------- report */
print_report:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    la      a0, str_banner
    jal     ra, puts
    la      a0, str_lanes
    jal     ra, puts
    andi    a0, s6, 0xff
    jal     ra, print_dec
    la      a0, str_clk
    jal     ra, puts
    srli    a0, s6, 8
    andi    a0, a0, 0xff
    jal     ra, print_dec
    la      a0, str_taps
    jal     ra, puts
    mv      a0, s7
    jal     ra, print_dec
    la      a0, str_samples
    jal     ra, puts
    li      a0, DEMO_SAMPLES
    jal     ra, print_dec
    la      a0, str_expected
    jal     ra, puts
    mv      a0, s8
    jal     ra, print_hex
    la      a0, str_crlf
    jal     ra, puts

    li      a4, 0                  # architecture index
    addi    a5, s2, TABLE_OFFSET   # record pointer
report_architecture:
    la      a0, str_arch
    jal     ra, puts
    la      a0, arch_names
    slli    t0, a4, 3
    add     a0, a0, t0
    jal     ra, puts
    la      a0, str_check
    jal     ra, puts
    lw      t0, 20(a5)
    la      a0, str_pass
    bne     t0, zero, 1f
    la      a0, str_fail
1:  jal     ra, puts
    la      a0, str_cycles
    jal     ra, puts
    lw      a0, 4(a5)
    jal     ra, print_dec
    la      a0, str_compute
    jal     ra, puts
    lw      a0, 8(a5)
    jal     ra, print_dec
    la      a0, str_results
    jal     ra, puts
    lw      a0, 12(a5)
    jal     ra, print_dec
    la      a0, str_checksum
    jal     ra, puts
    lw      a0, 16(a5)
    jal     ra, print_hex
    la      a0, str_status
    jal     ra, puts
    lw      a0, 0(a5)
    jal     ra, print_hex
    la      a0, str_crlf
    jal     ra, puts
    addi    a5, a5, RECORD_BYTES
    addi    a4, a4, 1
    li      t0, 3
    blt     a4, t0, report_architecture

    la      a0, str_result
    jal     ra, puts
    la      a0, str_pass
    beq     s10, zero, 1f
    la      a0, str_fail
1:  jal     ra, puts
    la      a0, str_crlf
    jal     ra, puts
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

/* -------------------------------------------------------------- UART I/O */
# putc(a0): wait for TX_READY, then send the low byte. Clobbers t6.
putc:
    lw      t6, 4(s5)              # UART_STATUS
    andi    t6, t6, 1
    beq     t6, zero, putc
    sw      a0, 0(s5)              # UART_TXDATA
    ret

# puts(a0 = NUL-terminated string). Preserves a1.
puts:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    sw      a1, 4(sp)
    mv      a1, a0
puts_loop:
    lbu     a0, 0(a1)
    beq     a0, zero, puts_done
    jal     ra, putc
    addi    a1, a1, 1
    jal     zero, puts_loop
puts_done:
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    addi    sp, sp, 8
    ret

# print_dec(a0 = unsigned value): decimal by repeated subtraction of powers
# of ten (RV32I has no divider). Preserves a1-a3.
print_dec:
    addi    sp, sp, -16
    sw      ra, 0(sp)
    sw      a1, 4(sp)
    sw      a2, 8(sp)
    sw      a3, 12(sp)
    mv      a2, a0                 # remaining value
    la      a1, powers_of_ten
    li      a3, 0                  # a digit has been printed
print_dec_power:
    lw      t0, 0(a1)
    beq     t0, zero, print_dec_done
    li      t1, 0                  # digit
print_dec_subtract:
    bltu    a2, t0, print_dec_digit
    sub     a2, a2, t0
    addi    t1, t1, 1
    jal     zero, print_dec_subtract
print_dec_digit:
    bne     t1, zero, print_dec_emit
    bne     a3, zero, print_dec_emit
    li      t2, 1
    beq     t0, t2, print_dec_emit # always print the units digit
    jal     zero, print_dec_next
print_dec_emit:
    li      a3, 1
    addi    a0, t1, 48             # '0'
    jal     ra, putc
print_dec_next:
    addi    a1, a1, 4
    jal     zero, print_dec_power
print_dec_done:
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    lw      a2, 8(sp)
    lw      a3, 12(sp)
    addi    sp, sp, 16
    ret

# print_hex(a0): "0x" followed by eight lowercase hex digits. Preserves a1-a2.
print_hex:
    addi    sp, sp, -12
    sw      ra, 0(sp)
    sw      a1, 4(sp)
    sw      a2, 8(sp)
    mv      a2, a0
    la      a0, str_0x
    jal     ra, puts
    li      a1, 8
print_hex_digit:
    srli    a0, a2, 28
    li      t0, 10
    blt     a0, t0, 1f
    addi    a0, a0, 87             # 'a' - 10
    jal     zero, 2f
1:  addi    a0, a0, 48             # '0'
2:  jal     ra, putc
    slli    a2, a2, 4
    addi    a1, a1, -1
    bne     a1, zero, print_hex_digit
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    lw      a2, 8(sp)
    addi    sp, sp, 12
    ret

/* ------------------------------------------------------------- constants */
    .section .rodata
    .balign 4
powers_of_ten:
    .word 1000000000, 100000000, 10000000, 1000000, 100000
    .word 10000, 1000, 100, 10, 1, 0
arch_names:                        # 8-byte slots, indexed by ARCH_SEL
    .asciz "SEQ    "
    .asciz "PAR    "
    .asciz "PIPE   "
str_banner:   .asciz "\r\n=== NEXUS-32 board demo (PicoRV32 + 3 FIR engines) ===\r\n"
str_lanes:    .asciz "build: LANES="
str_clk:      .asciz " CLK_MHZ="
str_taps:     .asciz " TAP_COUNT="
str_samples:  .asciz " SAMPLE_COUNT="
str_expected: .asciz " golden_checksum="
str_arch:     .asciz "arch="
str_check:    .asciz " check="
str_cycles:   .asciz " cycles_total="
str_compute:  .asciz " compute_cycles="
str_results:  .asciz " result_count="
str_checksum: .asciz " checksum="
str_status:   .asciz " status="
str_result:   .asciz "NEXUS32 RESULT: "
str_pass:     .asciz "PASS"
str_fail:     .asciz "FAIL"
str_0x:       .asciz "0x"
str_crlf:     .asciz "\r\n"
