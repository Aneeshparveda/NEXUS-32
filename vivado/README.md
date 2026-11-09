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

`rtl/top_basys3.sv` is the board-level top module. It defaults to `LANES=8`
(16/32 are expected to exceed the 90 DSP48E1 slices when the selector builds
all three engines; pre-Vivado estimate) and instantiates `nexus32_soc` with the existing smoke firmware image. Its
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
  -tclargs results/vivado/basys3 8
```

The arguments are `<output_dir> <LANES>`; the defaults are
`results/vivado/basys3` and `8`. Supported lane values remain `4`, `8`, `16`,
and `32`; the source and simulation configurations are not removed if the
board default changes later. `RISCV_CC` and `RISCV_OBJCOPY` may be set
explicitly. When unset, the flow tries the `riscv64-elf-*` tool names followed
by `riscv64-unknown-elf-*`.

### Windows hosts (prebuilt inputs)

Windows has no bash or RISC-V toolchain, so the flow defaults to
`NEXUS32_INPUTS=prebuilt` there: it uses `vendor/picorv32/` and
`firmware/nexus32_smoke.hex` from a handoff zip made by
`bash scripts/make_vivado_bundle.sh`, verifies the pinned revision, the
PicoRV32 SHA-256 (when Tcl's `sha256` package is available) and the 4096-word
firmware image, and never calls bash, git or the toolchain. Run
`vivado\RUN_VIVADO_BASYS3.bat <LANES> [MHZ]`. The full procedure is in
[`docs/VIVADO_DAY.md`](../docs/VIVADO_DAY.md). Set `NEXUS32_INPUTS=build` or
`prebuilt` to override the platform default on any host.

After synthesis the flow checks that IMEM block RAMs carry a non-zero
`INIT_00`; a missing `$readmemh` image (a Vivado warning, not an error) would
otherwise produce a bitstream with empty instruction memory, or no IMEM at all
once the empty ROM is optimized away.

### SoC clock

The optional third argument (`MHZ` for the `.bat`) selects the SoC clock:
`100` (default) drives the SoC straight from the 100 MHz oscillator; `50` or
`25` instantiate an `MMCME2_BASE` (VCO 1000 MHz) plus `BUFG` in
`top_basys3.sv`. Vivado derives the generated clock from the existing
`create_clock`, so timing is checked at the slower period. The MMCM branch is
elaborated only for 50/25, so simulation of the default build needs no Xilinx
primitive models; the 50/25 path itself is checked only by Vivado.

### Firmware

`NEXUS32_FIRMWARE` selects the IMEM image: `demo` (default,
`firmware/nexus32_demo.hex`) runs a 1024-sample block on all three engines,
compares each against a golden checksum generated from the Python model by
`scripts/gen_demo_expected.py`, sets the LEDs and prints a report over the
UART (`uart_tx`, pin A18, 115200 8N1); `smoke` (`firmware/nexus32_smoke.hex`)
is the original four-tap LED-only check.

### Key metrics and metrics.txt

After the flow, `build_summary.md` gains a key-metrics table and
`metrics.txt` records `KEY=VALUE` lines: `BUILD_STATUS`, `LANES`,
`SYS_CLK_MHZ`, `FIRMWARE`, `COMMIT`, `VIVADO_VERSION`, `TIMING_MET`
(`YES` when post-implementation WNS and WHS are both ≥ 0), `WNS_NS`, `TNS_NS`,
`WHS_NS`, `THS_NS`, `LUT`, `FF`, `DSP`, `BRAM_TILES`, `IMEM_INIT_CHECK`,
`METRICS_SOURCE` and `BITSTREAM_SHA256`. Values are copied from the Vivado
reports; `N/A` means the report or value was absent. `metrics.txt` is written
even when the flow fails.

## One-click Windows flow and evidence tools

| Launcher (`vivado\`) | What it does |
|---|---|
| `RUN_ALL.bat` | L4 and L8 board builds at 100 MHz, L8 at 50 MHz if L8 missed timing, the core sweep, then `COLLECT_EVIDENCE.bat`; logs every step to `results\run_all_log.txt` |
| `RUN_VIVADO_BASYS3.bat [LANES] [MHZ]` | One board build into `results\vivado\basys3_l<LANES>[_<MHZ>mhz]\` |
| `RUN_VIVADO_CORES.bat` | Out-of-context characterization sweep into `results\vivado_core\` |
| `PROGRAM_BOARD.bat [build]` | `program_board.tcl`: programs the first build that passed, passed the IMEM check and met timing (preference L8, L8@50, L4, ...), via the Hardware Manager |
| `READ_UART.bat [COMx]` | `read_uart.ps1`: 15 s capture of the board report into `results\evidence\uart_log.txt` |
| `COLLECT_EVIDENCE.bat` | `collect_evidence.tcl`: `results\evidence\EVIDENCE.md` (board and core tables, UART verdict, run log, provenance), text reports copied, zipped to `nexus32-evidence.zip` |
| `OPEN_IN_VIVADO_GUI.bat [build]` | Opens the routed checkpoint in the GUI for floorplan/report screenshots |

`find_vivado.bat` is the shared Vivado lookup. `NEXUS32_NO_PAUSE=1` suppresses
the final pause (set by `RUN_ALL.bat`). The board-selection and collector
logic are covered offline by `scripts/test_evidence_tools.sh`; the
Hardware Manager and serial-port steps can only be exercised on Windows with
a board.

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
  rtl/nexus32_uart_tx.sv rtl/nexus32_soc.sv rtl/top_basys3.sv
```

These checks establish source-level consistency and simulator elaboration only.
They do not establish Vivado synthesis, timing closure, bitstream validity,
programming success, or physical Basys 3 behavior. The required manual bring-up
after a successful Vivado build is to program `top_basys3.bit`, release the
center button, and observe `led[0]` boot, `led[2]` completion/pass, and `led[3]`
remaining low; no physical-board test has been performed in this environment.
