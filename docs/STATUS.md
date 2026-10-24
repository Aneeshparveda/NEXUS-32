# NEXUS-32 Build Status

## Stage 5B local candidate verification — 24 October 2026

The current working-tree candidate was checked with a fresh `make test` in an
isolated, byte-verified copy of the candidate. The receipt is recorded at
`results/verification-closure/stage5b-20261024T125226Z/make-test.log`; it
describes the uncommitted candidate, not the public baseline commit.

- Python reference model: 14 unit tests passed.
- Q16.16 MAC and postprocess directed testbench passed.
- Sequential FIR engine directed testbench passed.
- Synchronous tap-source alignment testbench passed.
- Sample/coefficient BRAM testbench passed.
- Accelerator CSR/configuration/execution/ownership testbench passed.
- Accelerator system-bus mapping/result/error/ownership testbench passed after fixing the enum ternary assignment.
- Pinned PicoRV32 RV32I firmware boot and sequential-FIR end-to-end test passed.
- Invalid instruction fetch rejected locally without issuing an accelerator request.
- Bus backpressure/stability and SoC reset-recovery testbenches passed.
- Parallel FIR standalone test passed.
- Pipelined FIR standalone test passed.
- Three-way sequential/parallel/pipelined differential test: 78 cases passed
  at `LANES=4` and `LANES=32`, and 79 cases passed at `LANES=8` and `LANES=16`.
- Standalone architecture selector: 52 transactions checked; test passed.
- STATUS-property regression passed at `LANES=4`, `8`, `16`, and `32`.
- PicoRV32 protected-access, invalid-configuration, timeout, reset-recovery,
  and multi-architecture SoC tests passed.
- Firmware START-to-verdict latency at `LANES=32`: 129 cycles
  (`T_start=239`, `T_verdict=368`, verdict `0x600d600d`).
- Verification closure: `PASS=15`, `FAIL=0`, `NOT_RUN=0`.

The baseline Git revision remains
`65fb71fb38c7c65159e09d463d316ba1824c5b2c`. The Stage 1–5A candidate
changes remain uncommitted; they have not been released or merged.

The candidate update changes `fir_seq_accel.sv` to prefetch the validated sample/coefficient window from synchronous BRAM, dispatch it to the selected engine, and return the result through the existing commit port. The CTRL write uses `START` at bit 0, `RESET` at bit 1, and `ARCH_SEL` in bits [3:2]: `00` sequential, `01` parallel, `10` pipelined, `11` reserved/error. The selector is single-outstanding; full-wrapper throughput is not claimed to be one result per cycle.

No GitHub Actions run for this modified revision has been verified. The local
pass must not be represented as external CI evidence.

## Known limitations

- No real Vivado synthesis, implementation timing, utilization, DRC, or bitstream generation has been run; FPGA implementation and physical Basys 3 behavior remain unverified.
- The accelerator wrapper gathers tap data into packed vector registers before dispatch. The architecture selector serializes the whole wrapped transaction; its top-level throughput is not the standalone pipeline engine's 1-result/cycle throughput.
- `ARCH_SEL=11` is rejected; no adaptive/Auto policy is implemented.
- The CPU integration is single-master and does not yet implement DMA, UART, GPIO, Sample B, STREAM-DB, or the planned system debug monitor.
- PicoRV32 native memory has no dedicated error response input; the wrapper exposes sticky bus-fault status and returns zero on an errored MMIO response.
