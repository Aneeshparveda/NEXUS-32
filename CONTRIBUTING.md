# Contributing to NEXUS-32

## Reproduce the checks

The repository separates network-dependent provisioning from the offline
regression:

```bash
# Networked setup: provision the pinned PicoRV32 source and base firmware.
make setup

# Offline canonical regression after setup.
make test

# Additive canonical regression including the CPU bridge fault-data bench.
make test-all
```

Gated smoke checks are available via `bash scripts/run_rtl_smoke.sh`
(see the canonical regression above).

> **Gate-membership update — 2026-11-10.** Three of the four Wave B runners
> are now gated by both `make test-all` and CI, through the Makefile targets
> `golden` (`run_golden_regression.py`), `soc-block-1024`
> (`run_soc_block_1024.sh all` plus the negative modes `neg-n1`, `neg-n2`,
> `neg-n3`, `neg-n4a`, `neg-n4b`) and `subword` (`run_subword_smoke.sh`).
> `run_protected_access_smoke.sh all` is still manual only.
> `scripts/run_rtl_smoke.sh` now exits non-zero instead of printing SKIP
> when the pinned PicoRV32 source or the smoke firmware is absent.
> Verilator lint is gated by `scripts/lint_baseline.txt`: a project-RTL
> warning outside that reviewed list fails `make verilator` and CI.
> The 2026-10-25 note below is kept as history; where it disagrees with
> this update, this update is current.

The 2026-10-25 note:

> **Gate-membership note — 2026-10-25 (autonomous lab, working copy HEAD
> `db7cd79`).** No step of `make test`, `make test-all`, or
> `.github/workflows/nexus32-ci.yml` invokes the four manual runners
> below, so a failure in any of them does not cause `make test`,
> `make test-all`, or the CI job to fail. `make test` and CI are not the
> same gate: CI does not run `make test` or `make test-all`; it
> enumerates its own steps, so wiring a runner into a gate must be added
> to both the Makefile and CI to gate in both. Non-gating does not mean
> optional or skippable: a PASS here remains the only evidence for
> CPU-driven subword access, CPU-driven 1024-sample blocks,
> protected-access sweep behaviour, and Python-model-versus-engine
> agreement, and these runners must still be run after any RTL or
> firmware change touching those paths before the corresponding claim is
> made. Wiring decision deferred on 2026-10-25 for a stated reason: this
> environment has no simulator with which to sim-validate gate wiring,
> so wiring blind would itself be an unverified gate change. This note
> is disclosure only, not a decision not to wire. `run_golden_regression.py`,
> `run_subword_smoke.sh`, and `run_soc_block_1024.sh all` are wireable
> as-is as single steps (each builds its own firmware);
> `run_protected_access_smoke.sh all` is not wireable as a sweep without
> per-lane firmware work, since `LANES<32` fails preflight — and
> explicit `run_protected_access_smoke.sh 32` is wireable only after
> the script-label fix below, because `run_lane` still prints a
> "lane sweep" PASS line for a single lane.
> Exception: the *bench* `tb_nexus32_soc_protected_access` (not the sweep
> runner) is exercised by `scripts/run_rtl_smoke.sh` at its default
> `LANES=32` with no `-P LANES` override, sequential architecture only,
> `SAMPLE_COUNT=1`, `TAP_COUNT=32`, and only when
> `vendor/picorv32/picorv32.v` and `firmware/nexus32_smoke.hex` are
> present; otherwise that script prints SKIP and still passes. Under
> `make test` / `make test-all` / CI the prerequisites are provisioned
> first, so the bench is then hard-gated. That exception covers one
> bench at one lane and one architecture; it is not multi-lane or
> multi-architecture protected-access coverage. Do not quote
> `PASS: protected-access lane sweep LANES=32` from
> `run_protected_access_smoke.sh all` as sweep evidence: in `all` mode
> it ran one lane (the `LANES=32` fallback), not a sweep. Fixing that
> script label is deferred work, recorded in the lab backlog, not
> completed by this note. The closure gate's pure-RTL
> `tb_fir_seq_accel_block_1024` (no CPU, no firmware) is gated via
> `run_verification_closure.sh`; it does not cover the CPU-driven
> `tb_nexus32_soc_block_1024` path, which remains non-gating.

```bash
make golden soc-block-1024 subword               # gated since 2026-11-10
bash scripts/run_protected_access_smoke.sh all   # still manual
```

The protected-access command currently reports a **representative LANES=32**
fallback. The existing protected-access firmware configures `TAP_COUNT=32`, so
LANES below 32 fail preflight before the ownership assertions; this is not a
full protected-access lane sweep.

Generated files under `build/`, `results/`, and `vendor/` are local artifacts.
Do not add them to a change or replace retained evidence.

## Evidence discipline

Changes should be reviewable from exact evidence:

- cite the relevant file and line or procedure name;
- record the source SHA and configuration when a result depends on them;
- quote the relevant PASS line verbatim with the command that produced it; and
- distinguish simulation/toolchain evidence from Vivado, timing, bitstream, or
  physical-board evidence. A passing simulator or CI job is not board proof.

Do not invent FPGA utilization, timing slack, bitstream, or hardware results.

## Hardware-facing changes

RTL or XDC changes that alter sweep outputs, synthesis behavior, pin mapping,
or the bitstream must land before laptop day and must carry focused simulation
evidence. Vivado and physical-board results require the approved tool and board
workflow; they are not inferred from simulation.
