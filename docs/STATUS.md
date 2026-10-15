# NEXUS-32 Build Status

## Verified by user on macOS with Icarus Verilog before Milestone 13

- Python reference model: 13 unit tests passed.
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
- Three-way sequential/parallel/pipelined differential test: 70 cases passed.
- Standalone architecture selector: 52 transactions checked; test passed.

## Current milestone: CSR/BRAM architecture integration — awaiting Mac validation

The candidate update changes `fir_seq_accel.sv` to prefetch the validated sample/coefficient window from synchronous BRAM, dispatch it to the selected engine, and return the result through the existing commit port. The CTRL write uses `START` at bit 0, `RESET` at bit 1, and `ARCH_SEL` in bits [3:2]: `00` sequential, `01` parallel, `10` pipelined, `11` reserved/error. The selector is single-outstanding; full-wrapper throughput is not claimed to be one result per cycle.

Run these in order:

1. `bash scripts/run_arch_integration_smoke.sh`
2. `bash scripts/run_selector_smoke.sh`
3. `bash scripts/run_differential_smoke.sh`
4. `bash scripts/run_parallel_smoke.sh`
5. `bash scripts/run_pipelined_smoke.sh`
6. `bash scripts/build_smoke_firmware.sh`
7. `bash scripts/run_rtl_smoke.sh`

The new CSR/BRAM and PicoRV32 multi-architecture tests have not yet been verified on the user's Mac. Expected new messages:

- `PASS: CSR-driven sequential/parallel/pipelined execution, common results, ARCH_SEL validation, and soft reset`
- `PASS: PicoRV32 firmware selected sequential, parallel, and pipelined FIR; all results and commit count match`

## Known limitations

- No Vivado synthesis/implementation has been run; BRAM inference, DSP/LUT/FF utilization, timing closure, and bitstream generation remain unverified.
- The accelerator wrapper gathers tap data into packed vector registers before dispatch. The architecture selector serializes the whole wrapped transaction; its top-level throughput is not the standalone pipeline engine's 1-result/cycle throughput.
- `ARCH_SEL=11` is rejected; no adaptive/Auto policy is implemented.
- The CPU integration is single-master and does not yet implement DMA, UART, GPIO, Sample B, STREAM-DB, or the planned system debug monitor.
- PicoRV32 native memory has no dedicated error response input; the wrapper exposes sticky bus-fault status and returns zero on an errored MMIO response.
