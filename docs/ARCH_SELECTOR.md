# NEXUS-32 common FIR architecture selector

## Purpose

`fir_arch_selector.sv` gives the sequential, parallel, and pipelined FIR engines one shared packed-window ready/valid interface. It is an additive integration milestone; it does not change the PicoRV32 SoC or the existing accelerator CSR interface yet.

## Interface contract

- `arch_select_i = 0`: sequential engine.
- `arch_select_i = 1`: parallel engine.
- `arch_select_i = 2`: pipelined engine.
- `arch_select_i = 3`: reserved/invalid; returns a local error response.
- Tap count must be 1 through 32. Any other count returns a local error response with result 0 and cycles 0.
- Tap `k` is `sample_vector_i[k*32 +: 32]` and `coefficient_vector_i[k*32 +: 32]`.
- Numerical behavior remains signed Q16.16, signed 32x32->64 multiplication, sign-extension to 72-bit terms, one final arithmetic `>>> 16`, and signed int32 saturation.
- The selector serializes requests: one transaction may be outstanding across any of the three engines. `arch_select_i` is sampled on the accepted input transaction, and the selected engine owns that response until it is consumed. This first shell is for safe runtime selection and correctness; it is not a throughput-preserving streaming arbiter.
- Output result/error/valid are held stable until `out_valid_o && out_ready_i`. The sequential engine's pulse response is captured and held by the selector.
- Reset is active-high synchronous and clears an in-flight transaction, including pipeline valid state via the engine resets.
- `cycles_o` preserves each engine's published nominal/elapsed cycle convention. It should not be interpreted as a directly comparable end-to-end wall-clock latency without a measurement harness.

## Test

Run:

```bash
bash scripts/run_selector_smoke.sh
```

The test checks all three architecture choices against the same signed 72-bit reference function, directed cases, deterministic pseudo-random vectors, invalid requests, output stalls, and reset flush behavior.

The selector must pass its test on the developer's Mac before this milestone is considered complete. Once it passes, add the new module and test/docs/scripts to Git. SoC CSR integration, memory gather/prefetch, and system-level architecture selection are still future steps.
