# NEXUS-32 Build Status

## Owner-reported checkpoints — 2026-10-15

- Python Q16.16 golden-model unit tests: **13 passed**.
- Icarus arithmetic primitive testbench: **passed**.
- Icarus sequential FIR engine directed testbench: **passed**.
- Icarus one-cycle synchronous tap-source alignment testbench: **passed**.
- Icarus sample/coefficient BRAM testbench: **passed**.
- Icarus integrated accelerator CSR/configuration/execution/ownership testbench: **passed**.

These are directed simulation checks only. They do not establish Vivado synthesis, BRAM inference, timing closure, formal proof, board correctness, or research results.

## Milestone 6 delivered for owner-side validation: system bus adapter

New module: `rtl/nexus32_accel_bus.sv`.

- Single-master 32-bit request/response interface with registered one-cycle response pulses.
- Address decoding for coefficient RAM (`0x00020000–0x00020fff`), sample bank A (`0x00021000–0x00021fff`), result RAM (`0x00022000–0x00022fff`), and accelerator CSRs (`0x10005000–0x10005fff`).
- Synchronous host reads and full-word writes for sample/coefficient RAM.
- Result RAM is host-read-only and updated from successful accelerator result-commit events.
- Misaligned accesses, partial memory writes, writes to result RAM, and unmapped addresses return error responses. A sticky bus-fault output records bus errors.
- Host sample/coefficient writes during active accelerator ownership are rejected; the attempted write is also presented to the accelerator shell's ownership-denial logic.
- New end-to-end testbench: `tests/rtl/tb_nexus32_accel_bus.sv`.

**Owner-side validation is pending for Milestone 6.** Run:

```bash
python -m unittest discover -s tests -v
bash scripts/run_rtl_smoke.sh
```

Expected new message on success:

```text
PASS: NEXUS-32 system bus, RAM mapping, result commit, errors, and ownership tests
```

## Explicitly not implemented yet

- Full PicoRV32 SoC, instruction/data RAM, complete bus arbitration/fairness, unmapped-access debug monitor at `0x10006000`, watchdog, IRQ routing, UART/GPIO/timer, and firmware boot path.
- Sample bank B / ping-pong buffers, result-bank ownership protocol for streaming, DMA, multi-sample block iteration, and offered-load generation.
- Parallel and pipelined FIR engines; current execution path is sequential only.
- A second independent reference implementation, formal properties, mutation campaign, Verilator/cocotb regression, and continuous integration.
- Vivado synthesis/implementation, DRC, timing/resource reports, Basys 3 validation, and board-level power measurement.

Treat all reported tests as directed simulation evidence only. No device resource, Fmax, power, or hardware results are claimed yet.
