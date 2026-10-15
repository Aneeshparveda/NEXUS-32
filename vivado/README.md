# NEXUS-32 Vivado Core Characterization Flow

This directory contains the synthesis characterization suite for the parameterized NEXUS-32 FIR compute engines targeting the Digilent Basys 3 FPGA board (`xc7a35tcpg236-1`, Artix-7).

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
