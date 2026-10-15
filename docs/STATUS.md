# NEXUS-32 Build Status

## Verified by user on macOS with Icarus Verilog

- Python reference model: 13 unit tests passed.
- Q16.16 MAC and postprocess directed testbench passed.
- Sequential FIR engine directed testbench passed.
- Synchronous tap-source alignment testbench passed.
- Sample/coefficient BRAM testbench passed.
- Accelerator CSR/configuration/execution/ownership testbench passed.
- Accelerator system-bus mapping/result/error/ownership testbench passed after replacing the enum ternary with explicit `if/else` assignments in `rtl/nexus32_accel_bus.sv`.

## Current milestone: PicoRV32 integration

New files add a pinned upstream-core vendor script, bare-metal RV32I smoke firmware, an instruction-image converter, a CPU/native-memory bridge and SoC wrapper, and a processor-level end-to-end testbench.

This milestone is **not yet verified on the user's Mac**. Required commands:

1. `bash scripts/vendor_picorv32.sh`
2. `bash scripts/build_smoke_firmware.sh`
3. `bash scripts/run_rtl_smoke.sh`

Expected new message:
`PASS: PicoRV32 boot, RV32I firmware, memory bridge, and FIR accelerator end-to-end`

## Known limitations

- No Vivado synthesis/implementation has been run; BRAM inference, timing, utilization, and bitstream generation are unverified.
- The CPU integration is single-master and does not yet implement DMA, UART, GPIO, Sample B, STREAM-DB, or the planned system debug monitor.
- PicoRV32 native memory has no dedicated error response input; the wrapper exposes sticky bus-fault status and returns zero on an errored MMIO response.
