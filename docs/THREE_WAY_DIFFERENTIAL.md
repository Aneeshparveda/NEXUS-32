# NEXUS-32 three-way FIR differential test

This milestone adds a standalone testbench that drives the same legal transaction
window and tap count into the sequential, parallel, and pipelined FIR engines.
Each result is compared against a local signed 72-bit golden function implementing
full-width signed multiplication, sign extension, one final arithmetic shift by
16, and signed 32-bit saturation.

Coverage:

- Seven directed arithmetic cases: unity gain, negative fractional floor
  behavior, mixed signs, positive saturation, negative saturation, exact
  cancellation, and negative fractional accumulation.
- Lane-index sensitivity and maximum-valid-tap negative-saturation cases across
  the selected `LANES` configuration.
- Sixty-four deterministic pseudo-random full-width signed operand cases, with tap
  counts from 1 through the selected `LANES` value.
- Invalid tap-count checks for zero, above the selected lane count, and values
  above the architectural maximum, plus a mid-flight reset-recovery case.
- The vector remains stable until both ready/valid engines accept the transaction
  and until the sequential engine completes.
- Deterministic output-ready patterns force stalls in the parallel and pipelined
  output paths.
- Parallel `cycles_o` is checked against its one-cycle register contract; the
  pipelined engine's nominal `cycles_o` is checked against `clog2(LANES)+1`.

Run directly with:

```bash
bash scripts/run_differential_smoke.sh
```

The same regression is included in the canonical local gate:

```bash
make differential
```

Expected per-lane summaries on success:

```text
PASS: NEXUS-32 3-way differential FIR verification (LANES=4, 78 cases checked)
PASS: NEXUS-32 3-way differential FIR verification (LANES=8, 79 cases checked)
PASS: NEXUS-32 3-way differential FIR verification (LANES=16, 79 cases checked)
PASS: NEXUS-32 3-way differential FIR verification (LANES=32, 78 cases checked)
```

This tests transaction-level arithmetic equivalence and selected protocol/error
behavior for the listed cases. It is not a formal proof, does not test all
2^32 operands, and does not establish FPGA resource inference or timing
closure. The testbench uses its local signed 72-bit golden function; it does
not depend on the Python reference model.
