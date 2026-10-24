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

Focused Wave B checks are also available:

```bash
python3 scripts/run_golden_regression.py
bash scripts/run_subword_smoke.sh
bash scripts/run_soc_block_1024.sh all
bash scripts/run_protected_access_smoke.sh all
bash scripts/run_rtl_smoke.sh
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
