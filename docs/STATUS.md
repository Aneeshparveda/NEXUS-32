# NEXUS-32 Status

**Last updated: 2026-10-26.**

This file is the single detailed status record the README status banner
points to. The CI badge at the top of the README is the live CI signal;
the runs listed below are point-in-time checks.

## Current HEAD

- Last reviewed against main at `c74f5e1` ("Merge pull request #7 from
  Aneeshparveda/readme-revamp", verified from the repository history in
  this checkout).

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

## What is NOT claimed

- No LUT, DSP, or WNS numbers are claimed — no Vivado run has produced
  them yet, and no DSP estimate is stated in the README.
- No board evidence exists yet: no bitstream SHA-256, no LED observation
  notes, no dated board photo.
- No demo GIF, screenshot, or video exists yet.
- Board LANES is not promised: the board LANES value is chosen after
  Vivado synthesis utilisation is known. LANES=16 is a candidate, not a
  promised fit for the XC7A35T.
- The board wrapper default (LANES=16 in `rtl/top_basys3.sv`) and the
  integrated shell default (LANES=32) are source defaults, not fit or
  timing results.

## Known limitations

- No Vivado synthesis, implementation timing, utilization, DRC, or
  bitstream generation has been run; FPGA implementation and physical
  Basys 3 behaviour remain unverified. (README.md status banner)
- `ARCH_SEL=11` is rejected; no adaptive/Auto policy is implemented.
  (`docs/ACCELERATOR_CONTRACT_V1.md`; `rtl/fir_arch_selector.sv`)
- The CPU integration is single-master and does not yet implement DMA,
  UART, GPIO, Sample B, STREAM-DB, or the planned system debug monitor.
  (`rtl/fir_seq_accel.sv`)
- PicoRV32 native memory has no dedicated error response input; the
  wrapper exposes sticky bus-fault status and returns zero on an
  errored MMIO response.
  (`rtl/nexus32_accel_bus.sv`; `rtl/nexus32_soc.sv`; assumed: the pinned
  `picorv32.v` was not checked)
