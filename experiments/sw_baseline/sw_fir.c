/*
 * Software-only FIR baseline for the NEXUS-32 CPU (PicoRV32, RV32I, no
 * multiplier). Same contract as the accelerator: Q16.16, 72-bit accumulate
 * (64-bit is enough for the demo data), >> 16, int32 saturation, zero history
 * at the block start, TAP_COUNT = LANES, same samples and coefficients as the
 * board demo. Cycles are read from the CPU's own rdcycle counter.
 *
 * DMEM result: [0] boot sig, [2] 0x600d600d if the checksum matches the golden
 * value, [0x40] cycles for the whole 1024-sample block, [0x41] checksum,
 * [0x42] tap count.
 */
typedef unsigned int uint32_t;
typedef int int32_t;
typedef long long int64_t;

#define DMEM   ((volatile uint32_t *)0x00010000u)
#define SYSPG  ((volatile uint32_t *)0x10006000u)
#define SAMP   ((volatile int32_t  *)0x00010800u)   /* 1024 words */
#define COEF   ((volatile int32_t  *)0x00011800u)   /*   32 words */
#define N      1024

#ifndef CHK_T4
#define CHK_T4  0u
#define CHK_T8  0u
#define CHK_T16 0u
#define CHK_T32 0u
#endif

static inline uint32_t rdcycle(void) {
    uint32_t v;
    __asm__ volatile(".insn i 0x73, 2, %0, x0, -1024" : "=r"(v)); /* csrrs rd, cycle, x0 */
    return v;
}

__asm__(".section .text.init,\"ax\",@progbits\n"
        ".globl _start\n"
        "_start:\n"
        "  lui sp, 0x14\n"
        "  jal ra, main\n"
        "1: j 1b\n");

void main(void) {
    DMEM[0] = 0x4e583332u;
    uint32_t taps = SYSPG[2] & 0xffu;
    uint32_t expect = taps == 4 ? CHK_T4 : taps == 8 ? CHK_T8 : taps == 16 ? CHK_T16 : taps == 32 ? CHK_T32 : 0xffffffffu;

    for (int k = 0; k < 32; k++) COEF[k] = 0x8000 - k * 0x800;
    uint32_t s = 0x00012345u;
    for (int i = 0; i < N; i++) {
        s = s * 5u + 0x00030001u;
        SAMP[i] = (int32_t)s >> 12;
    }

    uint32_t t0 = rdcycle();
    uint32_t chk = 0;
    for (int n = 0; n < N; n++) {
        int64_t acc = 0;
        for (uint32_t k = 0; k < taps && k <= (uint32_t)n; k++)
            acc += (int64_t)SAMP[n - k] * (int64_t)COEF[k];   /* software multiply */
        int64_t sc = acc >> 16;
        int32_t out = sc > 2147483647LL ? 2147483647 : sc < -2147483648LL ? (int32_t)0x80000000 : (int32_t)sc;
        chk = ((chk << 5) | (chk >> 27)) ^ (uint32_t)out;
    }
    uint32_t t1 = rdcycle();

    DMEM[0x40] = t1 - t0;
    DMEM[0x41] = chk;
    DMEM[0x42] = taps;
    DMEM[2] = (chk == expect) ? 0x600d600du : 0xdead0001u;
}
