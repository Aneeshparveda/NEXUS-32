# NEXUS-32 common FIR architecture selector

## Purpose

`fir_arch_selector.sv` gives the sequential, parallel, and pipelined FIR engines one shared packed-window ready/valid interface. Milestone 13 connects this selector to the existing accelerator CSR shell through a synchronous BRAM gather/prefetch stage.

## Interface contract

- `arch_select_i = 0`: sequential engine.
- `arch_select_i = 1`: parallel engine.
- `arch_select_i = 2`: pipelined engine.
- `arch_select_i = 3`: reserved/invalid in this build; returns a local error response and is rejected by the accelerator CTRL command before data is prefetched.
- Tap count must be 1 through 32.
- Tap `k` is `sample_vector_i[k*32 +: 32]` and `coefficient_vector_i[k*32 +: 32]`.
- Numerical behavior remains signed Q16.16, signed 32x32->64 multiplication, sign-extension to 72-bit terms, one final arithmetic `>>> 16`, and signed int32 saturation.
- The selector serializes requests: one transaction may be outstanding across any of the three engines. `arch_select_i` is sampled on the accepted input transaction, and the selected engine owns that response until it is consumed.
- Output result/error/valid are held stable until `out_valid_o && out_ready_i`. The sequential engine's pulse response is captured and held by the selector.
- Reset is active-high synchronous and clears an in-flight transaction, including pipeline valid state via the engine resets.
- `cycles_o` preserves each engine's published nominal/elapsed cycle convention. Compare measured whole-accelerator latency using the controller CSRs, not this value alone.

## CSR integration

Architecture selection is encoded in a complete write to `CTRL` at accelerator-relative offset `0x00`:

```text
bit 0    START
bit 1    RESET (takes priority over START)
bits 3:2 ARCH_SEL (00 sequential, 01 parallel, 10 pipelined, 11 reserved/error)
bits 31:4 must be zero
```

The accelerator validates pointers and tap count, owns the sample/coefficient banks, gathers tap pairs from synchronous BRAM into stable vectors, submits one selected-engine operation, and commits the result through the existing result-commit interface. Because this selector allows one outstanding request, it does not preserve one-result-per-cycle throughput through the full CSR/BRAM wrapper.

## Tests

```bash
bash scripts/run_selector_smoke.sh
bash scripts/run_arch_integration_smoke.sh
bash scripts/run_differential_smoke.sh
```

The selector test checks all three architecture choices against the same signed 72-bit reference function, directed cases, deterministic pseudo-random vectors, invalid requests, output stalls, and reset flush behavior. The accelerator integration test exercises all three choices through the CSR shell and BRAM prefetch path. The PicoRV32 multi-architecture test in the full regression exercises the same CTRL choices through the mapped system bus.
