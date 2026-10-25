# Verification Closure: Serialized Block Processing

## Status and provenance

This report records simulation evidence for the serialized multi-sample
controller. It does not amend the normative contract or claim that every V1.0
implementation-deviation row is closed.

- Documentation branch: `docs/refresh-block-processing-status`
- Documentation branch base: `5110ad17c255a1184cb792b6862180f18225912d`
- Relevant implementation/test commits:
  - `3e709d1` — serialized block-processing controller
  - `baa433b` — physical result-commit guard alignment
  - `ae15dd8` — block-closure scoreboards and experiment runner
  - `5110ad1` — reset-edge physical-write observation correction
- Normative behavior source: [`ACCELERATOR_CONTRACT_V1.md`](ACCELERATOR_CONTRACT_V1.md)

The closure runner receipt was captured on `2026-10-18T21:09:30Z` with
Icarus Verilog 13.0. The runner recorded branch
`feature/verification-closure` and source revision
`ae15dd8b589459b515d2b1646ad6e2e985b4dc90`. The reset-edge scoreboard
correction was present in the worktree for that run and was committed
immediately afterward as `5110ad1`; it changed verification observation only,
not the DUT RTL. This distinction is retained so the receipt is not
misattributed to a commit that did not exist when the script printed its
revision.

Generated binaries and logs remain under the ignored directory
`results/verification-closure/`. They are evidence for the reported run, not
repository deliverables.

## Hosted CI provenance addendum — 25 October 2026

The October 18, 2026 closure receipt above predates commit
`74f4f66eef483ea99569177e5781d8a91067862a`. The closure gate was re-run by
GitHub Actions on that commit in run
https://github.com/Aneeshparveda/NEXUS-32/actions/runs/40110889157.
This CI evidence remains simulation/toolchain evidence only; it is not Vivado
synthesis or implementation evidence, timing closure, bitstream evidence, or
physical Basys 3 board evidence.

## Hosted CI provenance addendum — run #6 on `db7cd79` — 25 October 2026

GitHub Actions run #6 on commit `db7cd79f5fed28b98a9834da650237a225264991` completed with job "Ubuntu simulation and toolchain regression" SUCCEEDED: https://github.com/Aneeshparveda/NEXUS-32/actions/runs/40137742496

All 23 steps shown in the GitHub Actions UI passed (the workflow file names 19 steps; the UI total includes Set up job, Post, and Complete job entries), and the workflow artifact `nexus32-verification-logs-40137742496` (87.2 KB) was uploaded. This addendum does not rewrite the run #5 receipt above, does not backfill any PASS, and claims no per-step log contents (per-step logs were not accessed). This CI evidence remains simulation/toolchain evidence only; it is not Vivado synthesis or implementation evidence, timing closure, bitstream evidence, or physical Basys 3 board evidence.

## Timeout bench semantics addendum — 25 October 2026

The timeout firmware in `firmware/nexus32_timeout.S` uses
`POLL_TIMEOUT=100000` and deliberately never issues `START`; it exercises the
finite polling loop against quiescent `STATUS=0`. The bench
`tests/rtl/tb_nexus32_soc_timeout.sv` asserts the T0-to-verdict delta is in
`[1,400,000, 6,000,000]` cycles with a 6,000,000-cycle watchdog, and its PASS
line records `cause=3`. The earlier observed delta of 4,200,025 cycles is
consistent with approximately 100,000 polls at approximately 42 cycles per
poll; it is a reported simulation observation, not a `CYCLES_TOTAL` value or a
calibration bound.

## What was measured

`tests/rtl/tb_fir_seq_accel_block_1024.sv` runs an independent signed Q16.16
reference model against the complete integrated block path. It does not use
the controller's sample windows, nominal engine cycle field, `BUSY`, or
`DONE` as its functional oracle. The scoreboard observes controller and bus
events directly:

- `SAMPLE_COUNT=1024` and `TAP_COUNT=3` were used for the full-block runs.
- All 1024 result words were compared with the independent reference.
- Input, output, and physical result-memory commit events were counted
  independently.
- The final physical commit address was checked as `0x0002_2ffc`.
- A successful result was checked with `BUSY=0`, `DONE=1`, `ERROR=0`, and
  `RESULT_COUNT=SAMPLE_COUNT`.
- The same bench injected a tap-BRAM range fault after eight commits and
  checked partial-result invalidation and RESET recovery.

Every event in the block scoreboard is sampled at the active rising edge
before nonblocking assignments (NBA). A `#1` delay is used only for
post-edge memory and CSR assertions. The event definitions are the contract's
§8 definitions:

| Event | Observation |
|---|---|
| `e_start` | Valid START accepted and ownership reserved. |
| `e_sample[n]` | Synchronous sample response captured into the pending register. |
| `e_in[n]` | `engine_in_valid && engine_in_ready` accepts window `n`. |
| `e_out[n]` | `engine_out_valid && engine_out_ready` transfers output `n`. |
| `e_commit[n]` | Output `n` is successfully written to result memory. |
| `e_done` | Rising edge of the final successful result-memory commit. |
| `e_error` | Rising edge on which an internal BRAM/engine fault terminates the run. |

For a successful run, the scoreboard checks
`CYCLES_TOTAL = e_done - e_start`. For an internal fault, it checks
`CYCLES_TOTAL = e_error - e_start`. When an engine output transfer exists, it
checks `COMPUTE_CYCLES = last e_out - first e_in`.

## 1024-sample success matrix

The matrix covers all four physical lane builds and all three selected
architectures: `arch=0` sequential, `arch=1` parallel, and `arch=2`
pipelined. Every row reported `inputs=1024`, `outputs=1024`,
`commits=1024`, `e_start=3`, `e_in[0]=12`, `STATUS=0x00000002`, zero
functional/counter/harness failures, and a complete reference match.

| LANES | Architecture | `e_out[last]` | `e_done` / final commit | `CYCLES_TOTAL` | `COMPUTE_CYCLES` |
|---:|---|---:|---:|---:|---:|
| 4 | Sequential | 9224 | 9225 | 9222 | 9212 |
| 4 | Parallel | 5128 | 5129 | 5126 | 5116 |
| 4 | Pipelined | 8200 | 8201 | 8198 | 8188 |
| 8 | Sequential | 9224 | 9225 | 9222 | 9212 |
| 8 | Parallel | 5128 | 5129 | 5126 | 5116 |
| 8 | Pipelined | 9224 | 9225 | 9222 | 9212 |
| 16 | Sequential | 9224 | 9225 | 9222 | 9212 |
| 16 | Parallel | 5128 | 5129 | 5126 | 5116 |
| 16 | Pipelined | 10248 | 10249 | 10246 | 10236 |
| 32 | Sequential | 9224 | 9225 | 9222 | 9212 |
| 32 | Parallel | 5128 | 5129 | 5126 | 5116 |
| 32 | Pipelined | 11272 | 11273 | 11270 | 11260 |

## Partial-fault timing matrix

Each fault run used `SAMPLE_COUNT=16`. The bench waited for eight successful
physical commits, forced the tap-BRAM range-fault indication, and then checked
the internal-fault termination. All rows retained exactly eight committed
words, set `STATUS.ERROR` (`0x00000004`), left `DONE=0` and `BUSY=0`, set
`DBG_STATUS.BRAM_FAULT`, preserved the earlier committed words, and left later
result words at their pre-run contents. `CTRL.RESET` cleared the error and all
partial counters after each run.

The common event values were `e_start=3`, `e_in[0]=12`, and
`RESULT_COUNT=8` at termination.

| LANES | Architecture | `e_error` | `e_out[last]` | `CYCLES_TOTAL` | `COMPUTE_CYCLES` |
|---:|---|---:|---:|---:|---:|
| 4 | Sequential | 83 | 80 | 80 | 68 |
| 4 | Parallel | 51 | 48 | 48 | 36 |
| 4 | Pipelined | 75 | 72 | 72 | 60 |
| 8 | Sequential | 83 | 80 | 80 | 68 |
| 8 | Parallel | 51 | 48 | 48 | 36 |
| 8 | Pipelined | 83 | 80 | 80 | 68 |
| 16 | Sequential | 83 | 80 | 80 | 68 |
| 16 | Parallel | 51 | 48 | 48 | 36 |
| 16 | Pipelined | 91 | 88 | 88 | 76 |
| 32 | Sequential | 83 | 80 | 80 | 68 |
| 32 | Parallel | 51 | 48 | 48 | 36 |
| 32 | Pipelined | 99 | 96 | 96 | 84 |

The separate reset-race acceptance coverage exercised 75 cases per lane build.
For both reset phases, it observed zero physical result writes and zero
commits; all four lane builds completed with zero functional, counter, and
harness failures. The testbench observation correction for the reset edge is
the `5110ad1` commit listed above.

## Direct pipelined-engine latency

`tests/rtl/tb_fir_pipelined_latency.sv` measured the direct engine with
`out_ready=1` and a 24-item no-stall stream, then exercised pipeline fill,
drain, and output backpressure. It compared output data and errors against an
independent reference, required no output gaps in the no-stall stream, and
checked that output data, error, and the reported cycle field remained stable
while the output was stalled.

| LANES | Tree levels | Registered stages | Reported `cycles_o` | Post-NBA visible latency | Transfer-edge latency |
|---:|---:|---:|---:|---:|---:|
| 4 | 2 | 4 | 3 | 3 | 4 |
| 8 | 3 | 5 | 4 | 4 | 5 |
| 16 | 4 | 6 | 5 | 5 | 6 |
| 32 | 5 | 7 | 6 | 6 | 7 |

The transfer-edge value is measured from the accepted input rising edge to the
corresponding output-transfer rising edge, with both `valid && ready` tests
sampled before NBA. The post-NBA visible value matches the nominal
`TREE_LEVELS+1` `cycles_o` field. The transfer-edge value is
`TREE_LEVELS+2`; it must not be confused with nominal pipeline depth or with
elapsed latency under output backpressure.

## Canonical verification gate

`bash scripts/run_verification_closure.sh` is the canonical closure gate for
the pure-RTL verification in this repository. It requires `iverilog` and
`vvp`; it does not require the vendored PicoRV32 source or an RISC-V compiler.
The separate `run_rtl_smoke.sh` and `run_soc_smoke.sh all` regressions retain
their existing PicoRV32 and firmware prerequisites.

The gate runs the following required test families:

| Family | Required configurations | Top-level testbench | Source/dependency note |
|---|---|---|---|
| Full 1024-sample block/timing | `LANES=4, 8, 16, 32` | `tb_fir_seq_accel_block_1024` | Integrated accelerator bus and RTL sources; no vendor CPU |
| Direct pipelined latency | `LANES=4, 8, 16, 32` | `tb_fir_pipelined_latency` | Direct pipeline RTL sources; no vendor CPU |
| Block-processing acceptance | `LANES=4, 8, 16, 32` | `tb_fir_seq_accel_block_processing` | Integrated accelerator bus and RTL sources; no vendor CPU |
| Block-configuration acceptance | Fixed `LANES=32` localparam | `tb_fir_seq_accel_block_config` | Direct accelerator RTL sources; the bench does not expose a parameter sweep |
| Configuration-stage acceptance | Fixed `LANES=32` localparam | `tb_fir_seq_accel_config_stage` | Direct accelerator RTL sources; the bench does not expose a parameter sweep |

> **Lab correction note — 2026-10-25 (autonomous lab, working copy HEAD
> `db7cd79`).** The table above lists 5 families, which expand to 14
> enumerated runs in the outcomes prose (4 + 4 + 4 + 1 + 1), while
> `scripts/run_verification_closure.sh` `REQUIRED_TESTS` requires **15**.
> The 15th, missing from this document, is `block_1024_max_seq_l32`
> (`LANES=32`, `TAP_COUNT_VALUE=32`, `ARCHITECTURE_COUNT=1`
> sequential-only, `RUN_FAULT_CASES=0`). Its outcome is **unreported in
> this document** — no matrix row and no PASS line for it are claimed here.
> The current script list is authoritative as of this note's date; this
> note does not retroactively claim the October receipt covered the 15th
> test.

The block-processing acceptance command pattern is:

```bash
iverilog -g2012 -Wall \
  -s tb_fir_seq_accel_block_processing \
  -Ptb_fir_seq_accel_block_processing.LANES=32 \
  -o results/verification-closure/tb_fir_seq_accel_block_processing_l32.vvp \
  rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
  rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv \
  rtl/fir_arch_selector.sv rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv \
  rtl/nexus32_accel_bus.sv \
  tests/rtl/tb_fir_seq_accel_block_processing.sv
vvp results/verification-closure/tb_fir_seq_accel_block_processing_l32.vvp
```

The same command is run independently with `LANES=4`, `8`, and `16`. The two
fixed-configuration acceptance benches use the same accelerator RTL source
list without a `-P` override because each declares `localparam int LANES=32`.

Each required test is recorded in
`results/verification-closure/status.tsv` as `PASS`, `FAIL`, or `NOT_RUN`.
Compilation failure, simulation failure, a missing required source, or a
missing mandatory simulator increments the gate failure count. The runner
continues to report the remaining tests where possible and exits nonzero if
any required test is `FAIL` or `NOT_RUN`; it never treats a missing mandatory
test as a successful closure. Per-test compile and simulation logs, generated
VVP files, and the exact command list remain under the ignored
`results/verification-closure/` directory.

Note (2026-10-25): a run that cannot start because a mandatory simulator
(`iverilog`/`vvp`) is missing no longer writes fresh `status.tsv` rows.
It exits nonzero before truncating any prior output and instead writes a
`CANNOT_RUN` marker in the same output directory stating the date, the
missing-tool reason, and that the existing log, command list and
`status.tsv` are from a prior run and are not evidence from this run.
A later runnable run clears that marker when it starts.

## Commands and reported outcomes

The following commands were run in the verification session and reported
successfully:

```bash
python3 -m unittest discover -s tests -v
bash scripts/run_rtl_smoke.sh
bash scripts/run_soc_smoke.sh all
bash scripts/run_verification_closure.sh
```

Observed outcomes:

- Python reference suite: 14 tests passed.
- RTL smoke: passed.
- SoC smoke: passed across the supported `LANES=4, 8, 16, 32` sweep.
- Verification closure: all four 1024-sample block scoreboards, all four
  direct pipeline experiments, all four block-processing acceptance runs, the
  fixed-LANES block-configuration acceptance run, and the fixed-LANES
  configuration-stage acceptance run passed; every summary reported zero
  functional, counter/latency, contract, or harness failures.
- `git diff --check` and `bash -n scripts/run_verification_closure.sh` also
  passed during the closure work.

The closure script is the reproducible entry point for the complete pure-RTL
gate and detailed matrices:

```bash
bash scripts/run_verification_closure.sh
```

It records the branch, source revision, UTC timestamp, Icarus/VVP versions,
compile commands, per-test status, and machine-readable result lines before
writing generated artifacts to `results/verification-closure/`. From a clean
checkout with Icarus installed, reproduce the gate with exactly:

```bash
bash scripts/run_verification_closure.sh
```

## Warnings and boundaries

The Icarus `-Wall` compile output contains the known
`constant selects in always_* processes are not fully supported` sensitivity
warnings for combinational processes in `fir_seq_accel.sv` and
`nexus32_accel_bus.sv`. They cause Icarus to broaden sensitivity, but did not
produce a functional, counter, latency, or harness failure in this closure.

This evidence does **not** claim:

- Vivado synthesis or implementation success;
- BRAM/DSP/LUT/FF resource usage, timing closure, Fmax, PPA, or power;
- bitstream generation, board programming, or physical Basys 3 behavior;
- standalone architecture throughput from the serialized selector/SoC path;
- stalled, elapsed pipeline latency as equivalent to the no-stall transfer
  latency above; or
- completion of unrelated V1.0 contract deviation rows or milestone
  checklist items.

The contract, RTL, firmware, and test benches are unchanged by this
documentation milestone. This report is a durable summary of the existing
simulation receipts and should be rerun after any behavior-affecting change.

## Addendum — 2026-10-25 (autonomous lab, working copy HEAD `db7cd79`)

This addendum is appended only. It does not rewrite, delete, or reorder the
receipt prose above, and it does not contradict the lab correction note in
the families-table section.

- Outcomes prose vs `REQUIRED_TESTS`: the "Commands and reported outcomes"
  prose above enumerates 14 runs (4 block + 4 pipeline + 4 block-processing
  + 1 block-configuration + 1 configuration-stage), while
  `scripts/run_verification_closure.sh` `REQUIRED_TESTS` requires 15. The
  15th, `block_1024_max_seq_l32`, is named in the lab correction note
  above; its outcome remains unreported in this document and is NOT
  claimed as PASS here. This addendum does not backfill a PASS.
- Python test count: the October receipt line above ("Python reference
  suite: 14 tests passed") records the count at that receipt's time
  (HEAD: 13 tests in `tests/test_fir_q16.py` + 1 in
  `tests/test_block_processing_vectors.py`). The working copy at this
  addendum's date contains 19 tests (18 in `tests/test_fir_q16.py` + 1 in
  `tests/test_block_processing_vectors.py`), and the suite was run during
  this docs-only edit with all 19 passing. That working-copy run is not a
  re-issue of the October receipt, and the 14 figure above is left
  unchanged as the historical receipt.
