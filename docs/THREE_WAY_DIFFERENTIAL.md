# NEXUS-32 three-way FIR differential test

This milestone adds a standalone testbench that drives the same legal transaction
window and tap count into the sequential, parallel, and pipelined FIR engines.
Each result is compared against a local signed 72-bit golden function implementing
full-width signed multiplication, sign extension, one final arithmetic shift by
16, and signed 32-bit saturation.

Coverage:

- Six directed cases: unity gain, negative fractional floor behavior, mixed signs,
  positive saturation, negative saturation, and all 32 taps active.
- Sixty-four deterministic pseudo-random full-width signed operand cases, with tap
  counts from 1 through 32.
- The vector remains stable until both ready/valid engines accept the transaction
  and until the sequential engine completes.
- Deterministic output-ready patterns force stalls in the parallel and pipelined
  output paths.
- Parallel `cycles_o` is checked against its one-cycle register contract; the
  pipelined engine's nominal `cycles_o` is checked against six.

Run with:

```bash
bash scripts/run_differential_smoke.sh
```

Expected summary on success:

```text
PASS: NEXUS-32 3-way differential FIR verification (70 cases)
```

This tests transaction-level arithmetic equivalence for the listed cases. It is
not a formal proof, does not test all 2^32 operands, and does not establish FPGA
resource inference or timing closure. Invalid tap counts are covered by the
architectures' individual unit tests rather than this legal-input differential
sweep.
