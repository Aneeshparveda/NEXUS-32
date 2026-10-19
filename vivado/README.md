# NEXUS-32 Vivado and Basys 3 Flows

This directory contains both the out-of-context FIR characterization suite and
the integrated Basys 3 implementation flow for the NEXUS-32 SoC. The target is
the Digilent Basys 3 rev-B board using Artix-7 part `xc7a35tcpg236-1`.

## Characterization Scope

The characterization suite runs out-of-context block-level synthesis for:
1. **Standalone Sequential Engine (`fir_seq_engine`)**: Unparameterized, handles 1–32 taps.
2. **Parallel Engine (`fir_parallel_engine`)**: Swept across `LANES = 4, 8, 16, 32`.
3. **Pipelined Engine (`fir_pipelined_engine`)**: Swept across `LANES = 4, 8, 16, 32`.
4. **Architecture Selector (`fir_arch_selector`)**: Swept across `LANES = 4, 8, 16, 32` to measure the combined area of all three engines integrated into a unified frontend.

In addition, an elaboration guard test verifies that unsupported configurations (such as `LANES = 12`) are cleanly rejected at synthesis elaboration time.

## Flow Architecture

- **Synthesis Mode**: Non-project batch mode (`create_project -in_memory`, `read_verilog -sv`, `read_xdc`, `synth_design -mode out_of_context`).
- **Clock Constraint**: Virtual 100 MHz clock (10.000 ns) applied to `clk_i` in `core_clock.xdc`. Input and output delays are normalized to 0.000 ns to provide a uniform block-level baseline. The clock and reset ports are excluded from data input delays.
- **Isolation**: Each configuration runs in an isolated in-memory session, saving individual logs and reports to `results/vivado_core/<case_id>/reports/`.

## Running the Characterization

### On Windows
Run `vivado/RUN_VIVADO_CORES.bat` or execute in Vivado Tcl Shell:
```tcl
cd <repo_root>
source vivado/run_core_characterization.tcl
```

### On Linux / Bash
```bash
bash scripts/run_vivado_char.sh [output_dir]
```

## Integrated Basys 3 build

### Board top and physical interfaces

`rtl/top_basys3.sv` is the board-level top module. It defaults to `LANES=16`
and instantiates `nexus32_soc` with the existing smoke firmware image. Its
ports are:

| Port | Direction | Board connection | Meaning |
|---|---|---|---|
| `clk_100mhz` | input | Basys 3 `W5` | 100 MHz oscillator |
| `btn_center` | input | Basys 3 `U18` | Active-high reset request |
| `led[0]` | output | `U16` | Firmware boot signature observed |
| `led[1]` | output | `E19` | Accelerator busy |
| `led[2]` | output | `U19` | Accelerator DONE or firmware PASS |
| `led[3]` | output | `V19` | CPU trap, bus fault, or accelerator error |

The pin assignments and `LVCMOS33` standards are in
`constraints/basys3.xdc`, based on Digilent's Basys-3 rev-B master XDC. The
clock is constrained as `sys_clk_pin` with a 10.000 ns period and a `{0 5}`
waveform. The center button is asynchronous to the clock; the wrapper asserts
reset immediately and releases it through a two-flop synchronizer. The SoC
itself retains its active-high, synchronous reset semantics.

### Firmware initialization

The SoC instruction memory is a synthesizable 4096-word array initialized by
`$readmemh(IMEM_INIT_FILE, imem)`. The integrated flow first runs
`scripts/build_smoke_firmware.sh`, which compiles
`firmware/nexus32_smoke.S` and converts the flat binary to
`firmware/nexus32_smoke.hex`. The build Tcl passes the normalized absolute
image path as the `IMEM_INIT_FILE` generic, so memory initialization does not
depend on Vivado's launch directory. Data memory is intentionally runtime
initialized by the firmware and is not preloaded.

The pinned PicoRV32 source is required at
`vendor/picorv32/picorv32.v`. If it is absent, the integrated flow invokes
`scripts/vendor_picorv32.sh`, which verifies the pinned upstream revision and
requires network access for the initial checkout.

### Build command

Run from the repository root on a machine with a licensed Vivado installation,
the RISC-V compiler/binutils, and the required board files:

```bash
vivado -mode batch -nojournal -nolog \
  -source vivado/build_basys3.tcl \
  -tclargs results/vivado/basys3 16
```

The arguments are `<output_dir> <LANES>`; the defaults are
`results/vivado/basys3` and `16`. Supported lane values remain `4`, `8`, `16`,
and `32`; the source and simulation configurations are not removed if the
16-lane board build is changed later. `RISCV_CC` and `RISCV_OBJCOPY` may be set
explicitly. When unset, the flow tries the `riscv64-elf-*` tool names followed
by `riscv64-unknown-elf-*`.

The flow uses an explicit non-project sequence: in-memory project creation,
source and XDC ingestion, synthesis, post-synthesis reports/checkpoint,
optimization, placement, optional `phys_opt_design`, routing,
post-implementation reports/checkpoint, and bitstream generation. A missing
mandatory source, tool, firmware image, Vivado command, report, checkpoint, or
bitstream makes the Tcl process exit nonzero. `phys_opt_design` is the only
optional implementation stage; it is skipped only when the command is absent.

Generated files are kept under the ignored output directory:

- `build_summary.tsv`: machine-readable metadata, stage statuses, source
  manifest, report paths, and artifact paths;
- `build_summary.md`: readable stage and artifact summary;
- `reports/post_synth/`: synthesis utilization, timing, clocks,
  unconstrained paths, DRC, and checkpoint;
- `reports/post_implementation/`: implementation utilization, timing, clocks,
  unconstrained paths, DRC, and checkpoint;
- `top_basys3.bit`: generated bitstream, when all required stages pass;
- bitstream property, size, and SHA-256 summaries when available.

The summary reports actual tool outputs and does not infer LUT, FF, DSP, BRAM,
WNS, or TNS values. Vivado is not installed in the current development
environment, so no synthesis, implementation, timing, bitstream, or physical
board result is claimed here.

## Generated Outputs

For each configuration under `results/vivado_core/<case_id>/reports/`:
- `<case_id>_utilization.rpt`: Top-level resource utilization (LUTs, FFs, DSPs, BRAMs).
- `<case_id>_utilization_hier.rpt`: Hierarchical breakdown of logic usage.
- `<case_id>_timing_summary.rpt`: Timing summary including Worst Negative Slack (WNS).
- `<case_id>_critical_paths.rpt`: Top 20 critical timing paths.
- `<case_id>_post_synth_drc.rpt`: Post-synthesis Design Rule Checks.
- `<case_id>_post_synth.dcp`: Full synthesized checkpoint netlist.
- `<case_id>_post_synth.v`: Structural Verilog simulation netlist.

Consolidated summaries:
- `results/vivado_core/characterization_summary.md`: Markdown summary table.
- `results/vivado_core/characterization_summary.csv`: Machine-readable CSV metrics.

## Interpretation Limits

1. **Out-of-Context Synthesis**: This characterizes standalone compute engines; it excludes PicoRV32 CPU, system bus, BRAM gather/prefetch logic, and arbitration.
2. **Timing Closure**: Out-of-context synthesis timing reports estimate logic delay and net routing. It is not final post-route timing closure on a programmed FPGA.
3. **Sequential Engine Area**: The sequential engine logic is unparameterized and identical across lane sweeps.

## Validation status

The wrapper and XDC can be checked without Vivado:

```bash
python3 scripts/check_basys3_constraints.py
iverilog -g2012 -Wall -s top_basys3 -o /tmp/nexus32_top_basys3.vvp \
  vendor/picorv32/picorv32.v \
  rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
  rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
  rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
  rtl/nexus32_soc.sv rtl/top_basys3.sv
```

These checks establish source-level consistency and simulator elaboration only.
They do not establish Vivado synthesis, timing closure, bitstream validity,
programming success, or physical Basys 3 behavior. The required manual bring-up
after a successful Vivado build is to program `top_basys3.bit`, release the
center button, and observe `led[0]` boot, `led[2]` completion/pass, and `led[3]`
remaining low; no physical-board test has been performed in this environment.
