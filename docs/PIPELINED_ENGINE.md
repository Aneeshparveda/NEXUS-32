# NEXUS-32 Pipelined FIR Engine — Milestone 10

## Scope

This milestone adds a standalone pipelined direct-form FIR engine. It does not change `nexus32_soc.sv`, the CSR controller, or the existing sequential/parallel implementations.

## Numerical contract

- Signed Q16.16, 32-bit samples and coefficients.
- Signed 32×32 -> 64-bit multiplication.
- Each product is sign-extended to 72 bits before tree addition.
- No intermediate rounding or saturation.
- One final arithmetic right shift by 16, then saturation to signed int32.
- Tap `k` is packed at `[k*32 +: 32]` in each input vector.
- `tap_count_i` values 1–32 are valid.
- Every accepted input yields an ordered output response. Invalid tap counts yield `out_valid_o=1`, `out_error_o=1`, and result zero.

## Pipeline contract

The seven elastic register stages are:

1. 32 products
2. 16 pairwise sums
3. 8 four-term sums
4. 4 eight-term sums
5. 2 sixteen-term sums
6. 32-term root sum
7. final shift/saturation output register

The output becomes visible six clock periods after the input-accepting edge. With no downstream stalls the engine can accept and retire one transaction per cycle after fill. `cycles_o=6` communicates the nominal unstalled pipeline depth; it does not count elapsed cycles while valid/ready stalls occur.

Ready propagates from the output register to the input. While `out_valid_o=1` and `out_ready_i=0`, output valid, error, result, and cycles are held stable. Reset clears valid/error pipeline state and the output state; data registers without valid state are intentionally not reset.

## Local test

```bash
bash scripts/run_pipelined_smoke.sh
```

The testbench checks signed 1-/3-/32-tap cases, saturation, invalid tap counts, sustained one-result-per-cycle throughput after fill, backpressure, output stability, and reset flushing. These results need to be confirmed on the developer's machine. Vivado synthesis/timing and SoC integration are separate follow-up steps.
