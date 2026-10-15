# NEXUS-32 — Runtime FIR Architecture Integration (Milestone 13)

## What changed

The `fir_seq_accel` shell now instantiates `fir_arch_selector` instead of directly instantiating only the sequential engine. The existing host-visible address map is preserved; architecture selection is encoded in the write to `CTRL` at accelerator-relative offset `0x00`.

| CTRL field | Meaning |
|---|---|
| bit 0 | `START` |
| bit 1 | `RESET`; takes priority over `START` and aborts the active operation |
| bits 3:2 = `00` | Sequential FIR |
| bits 3:2 = `01` | Parallel FIR |
| bits 3:2 = `10` | Pipelined FIR |
| bits 3:2 = `11` | Reserved in this build; start is rejected and `ERROR` becomes sticky |
| bits 31:4 | Must be zero |

Examples:

```text
0x00000001  START sequential
0x00000005  START parallel
0x00000009  START pipelined
0x00000002  soft reset (aborts an active run)
```

`AUTO` is intentionally **not implemented** here. It is not silently mapped to one of the three fixed architectures.

## Memory and ownership path

The accelerator validates the existing pointers and tap count before starting. After `START` is accepted, it owns the sample and coefficient banks, gathers the requested tap pairs from the synchronous BRAM interface into stable vectors, and then submits one operation to the selected architecture. Results return through the existing result-commit interface, so the bus's result memory write-through behavior remains unchanged.

The prefetch adapter means the input vectors are stable when the selected engine samples them. The adapter adds latency and is shared across all architecture choices. `CYCLES_TOTAL` measures from accepted `START` through selected-engine completion. `COMPUTE_CYCLES` measures from the first tap data transfer through result transfer; it is not just the tap count.

The selector allows only one outstanding operation. Consequently, this integration shell does **not** claim a continuous one-result-per-cycle throughput through the entire accelerator. The pipelined engine's standalone throughput test remains a separate result.

## Validation

Run:

```bash
bash scripts/run_arch_integration_smoke.sh
bash scripts/run_selector_smoke.sh
bash scripts/run_differential_smoke.sh
bash scripts/run_rtl_smoke.sh
```

The new `tb_fir_accel_architectures.sv` test configures the real accelerator CSR shell and synchronous tap BRAM, runs all three architectures on identical four-tap unity inputs, checks the common result `0x00040000` (4.0 in Q16.16), checks timing/status counters, rejects architecture code `11`, and tests soft reset during an in-flight run.

Do not mark this milestone complete until the new directed test and the existing regression both pass on the target development machine. This is still RTL simulation evidence, not Vivado synthesis, FPGA timing closure, or board measurement.
