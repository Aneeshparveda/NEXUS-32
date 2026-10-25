> **Lab addendum — 2026-10-25 (autonomous lab, working copy HEAD `db7cd79`).
> The milestone text below is preserved verbatim. Two pre-addendum claims
> are superseded, and only those two: the connection clause of pre-addendum
> line 5 ("not yet connected to the SoC bus or the sample/coefficient
> BRAM") and the adapter clause of pre-addendum line 37 ("a BRAM
> gather/prefetch adapter is required before architectural selection can
> switch"). Since Milestone 13 (`docs/ACCEL_ARCH_INTEGRATION.md`),
> `fir_seq_accel` instantiates `fir_arch_selector`, which instantiates the
> parallel engine (CTRL bits 3:2 = `01`), and the connection is via the
> selector plus the BRAM gather/prefetch adapter feeding stable vectors —
> not a direct BRAM port on the engine itself. Carve-outs: pre-addendum
> line 5's arithmetic description (32-tap window, 32 multipliers, 32-to-1
> tree) holds only at the default LANES=32 — the engine is now
> parameterized (LANES 4/8/16/32); pre-addendum line 37's final clause
> (resource inference, DSP count, post-synthesis timing, and bitstream
> functionality not yet measured) is **still true**. The remainder of this
> milestone document was not re-verified in this change.

# NEXUS-32 Parallel FIR Engine — first RTL milestone

## Scope

`rtl/fir_parallel_engine.sv` is a stand-alone, synthesizable parallel direct-form FIR arithmetic engine. It is not yet connected to the SoC bus or the sample/coefficient BRAM. It accepts a complete 32-tap window through packed input vectors, evaluates the active terms with 32 signed multipliers, zero-pads inactive terms, and reduces the products using a fixed 32-to-1 balanced tree.

## Numeric contract

- Signed Q16.16 sample and coefficient words.
- Per-tap signed 32x32 to 64-bit product.
- Each product is sign-extended into a signed 72-bit Q40.32 sum before reduction.
- No intermediate rounding or saturation.
- One final arithmetic right shift by 16, then signed 32-bit saturation.
- Tap 0 occupies bits `[31:0]`; tap `k` occupies `[k*32 +: 32]`.
- Accepted tap counts are 1 through 32 inclusive. Invalid counts produce `error_o` and no output.

## Handshake and timing

- Input transaction is accepted on a rising edge when `in_valid_i && in_ready_o`.
- The registered `out_valid_o` and `out_result_o` become visible after that edge.
- With `out_ready_i=1`, a new input can be accepted every cycle (II=1).
- If output is backpressured, `out_valid_o`, `out_result_o`, and `cycles_o` remain stable and `in_ready_o` deasserts.
- `cycles_o` reports the one-cycle register latency for each successful transaction; it is not a wall-clock performance counter.

## Local test

Run:

```bash
bash scripts/run_parallel_smoke.sh
```

The testbench uses an independent 72-bit reference function and covers 1, 3, and 32 taps, signed combinations, maximum/minimum saturation, a 32-term maximum-magnitude accumulation, invalid counts, and output backpressure. The testbench must pass on the developer machine before this milestone is accepted. Run the existing SoC regression separately with `bash scripts/run_rtl_smoke.sh`.

## Known integration boundary

The SoC currently integrates the sequential engine. The parallel engine consumes a packed window, so a BRAM gather/prefetch adapter is required before architectural selection can switch between sequential and parallel engines. Resource inference, DSP count, post-synthesis timing, and bitstream functionality have not yet been measured.
