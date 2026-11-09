# NEXUS-32 Status

**Last updated: 2026-11-10.**

This file is the single detailed status record the README status banner
points to. The CI badge at the top of the README is the live CI signal;
the runs listed below are point-in-time checks.

## Current HEAD

- Last reviewed against main at `c74f5e1` ("Merge pull request #7 from
  Aneeshparveda/readme-revamp", verified from the repository history in
  this checkout).
- Branch `feature/vivado-windows-handoff` (2026-11-10) adds the Windows
  Vivado flow, the UART board demo and the evidence tools. It was verified
  locally with `make test-all` (Icarus 13.0, Verilator 5.052) and the four
  manual runners; hosted CI on that branch is not yet verified.

## CI status

- CI run #12 on `c74f5e1`: completed, conclusion **success**
  (verified 2026-10-26 from the GitHub Actions API):
  https://github.com/Aneeshparveda/NEXUS-32/actions/runs/40233635198
- CI run #10 on `21d2db4`: completed, conclusion **success**
  (verified 2026-10-26 from the GitHub Actions API):
  https://github.com/Aneeshparveda/NEXUS-32/actions/runs/40227687445
- Earlier CI run #8 on `dabb71b` was the last verified run recorded in
  the previous README banner; it is superseded as the latest check by
  runs #10 and #12 above.
- CI on any commit pushed after this STATUS update is not yet verified
  and must be checked the same way before it is claimed.
- Passing CI is simulation and toolchain evidence only. It does not
  perform Vivado synthesis, timing closure, bitstream generation, board
  programming, or physical validation.

## What is claimed

- Simulation + CI verification of the PicoRV32 SoC with Sequential,
  Parallel, and Pipelined FIR accelerators under the frozen Q16.16
  contract in `docs/ACCELERATOR_CONTRACT_V1.md`.
- Functional block-processing cycle counts and verification closure as
  recorded in `docs/VERIFICATION_CLOSURE.md` and summarised in the README
  Results section (simulation only; see the caveat attached to that
  table — the integrated shell serializes to one outstanding operation,
  so those counts are not standalone architecture throughput or PPA).
- SoC START-to-verdict latency of 129 cycles at LANES=32 is a simulation
  figure only, not a board measurement and not `CYCLES_TOTAL`.
- Board demo firmware, simulation only: through PicoRV32, a 1024-sample block
  with `TAP_COUNT = LANES` matches the Python-golden checksum on all three
  engines at LANES 4/8/16/32, and the UART report is decoded independently by
  `tests/rtl/tb_nexus32_soc_demo.sv` (`scripts/run_soc_demo.sh all`).

## What is NOT claimed

- No LUT, DSP, or WNS numbers are claimed — no Vivado run has produced
  them yet. The README states only a labelled pre-Vivado fit estimate
  (LANES 16/32 likely exceed the 90 DSP48E1 with all three engines built),
  not a measurement.
- No board evidence exists yet: no bitstream SHA-256, no LED observation
  notes, no UART log from hardware, no dated board photo.
- The 50/25 MHz MMCM clock option in `rtl/top_basys3.sv` is checked only for
  elaboration with port stubs; Vivado has not yet synthesized it.
- No demo GIF, screenshot, or video exists yet.
- Board LANES is not promised: the board LANES value is chosen after
  Vivado synthesis utilisation is known. LANES=8 is the candidate, not a
  promised fit for the XC7A35T; LANES=16/32 are expected to exceed its 90
  DSP48E1 slices with all three engines built (pre-Vivado estimate).
- The board wrapper default (LANES=8 in `rtl/top_basys3.sv`) and the
  integrated shell default (LANES=32) are source defaults, not fit or
  timing results.

## Known limitations

- No Vivado synthesis, implementation timing, utilization, DRC, or
  bitstream generation has been run; FPGA implementation and physical
  Basys 3 behaviour remain unverified. (README.md status banner)
- `ARCH_SEL=11` is rejected; no adaptive/Auto policy is implemented.
  (`docs/ACCELERATOR_CONTRACT_V1.md`; `rtl/fir_arch_selector.sv`)
- The CPU integration is single-master and does not yet implement DMA,
  UART receive, GPIO, interrupts, Sample B, STREAM-DB, or the planned system
  debug monitor. The system page provides UART transmit and SYS_INFO only.
  (`rtl/fir_seq_accel.sv`, `rtl/nexus32_soc.sv`)
- PicoRV32 native memory has no dedicated error response input; the
  wrapper exposes sticky bus-fault status and returns zero on an
  errored MMIO response.
  (`rtl/nexus32_accel_bus.sv`; `rtl/nexus32_soc.sv`; assumed: the pinned
  `picorv32.v` was not checked)
