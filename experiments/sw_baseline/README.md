# Software-only FIR baseline

How fast is the same FIR on the NEXUS-32 CPU alone, without the accelerator? `sw_fir.c` runs the block in plain C on the PicoRV32 (RV32I, no multiplier). It uses the same data and arithmetic as the board demo:

- the same 1024 samples and 32 coefficients;
- Q16.16 arithmetic;
- 64-bit accumulation, `>> 16`, int32 saturation;
- zero history at the start of the block;
- TAP_COUNT = LANES.

The CPU's own cycle counter (`rdcycle`) times only the filter loop. The result is checked against the golden checksum, so the software computes exactly the same outputs as the hardware.

## Results (RTL simulation, Icarus Verilog)

| Taps | CPU alone (cycles) | Checksum (= golden) | SEQ | PAR | PIPE | Best speed-up |
|---:|---:|:---:|---:|---:|---:|---:|
| 4 | 6,763,452 | `0x8c4ef45f` | 10,248 | 5,128 | 8,200 | 1,319x (PAR) |
| 8 | 13,289,345 | `0xb2be7f16` | 14,352 | 5,136 | 9,232 | 2,587x (PAR) |
| 16 | 25,529,660 | `0x998bb932` | 22,560 | 5,152 | 10,272 | 4,955x (PAR) |
| 32 | 81,999,748 | `0x4768415f` | 38,976 | 5,184 | 11,328 | 15,818x (PAR) |

- The engine columns are the accelerator's `cycles_total` for the same block. The LANES=8 values were confirmed on the Basys 3 (`results/board_2026-11-13/`).
- At 50 MHz, the 8-tap software run takes 265.8 ms. The engines take 287 µs (SEQ), 184.6 µs (PIPE) and 102.7 µs (PAR).

Raw outputs: `result_l4.txt`, `result_l8.txt`, `result_l16.txt`, `result_l32.txt`.

## Limits

- This is plain C at `-O2` using libgcc's `__muldi3`, about 1,600 cycles per multiply-accumulate at 8 taps. A hand-written assembly multiply could be a few times faster, so the speed-ups shown are upper bounds, not exact numbers.
- The 32-tap run costs more per multiply-accumulate than the 16-tap run. The cause was not investigated; the likely reason is that the multiply routine slows down with larger values.
- These numbers come from simulation, not from the board.

## Reproduce

Needs `riscv64-elf-gcc` (with the rv32i/ilp32 multilib) and Icarus Verilog. The 8-tap run takes about 10 minutes and the 32-tap run longer.

```bash
bash experiments/sw_baseline/run.sh 8
```
