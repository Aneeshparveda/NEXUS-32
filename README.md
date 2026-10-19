# NEXUS-32 — PicoRV32 FIR SoC

NEXUS-32 is a PicoRV32-based SoC and a controlled comparison of three direct-form FIR architectures:

- an ordered, one-MAC-at-a-time sequential engine;
- a parallel engine with one multiplier per physical lane and a balanced reduction tree; and
- an elastic registered pipelined reduction tree.

The current integrated design is a simulation-verified, serialized block-processing controller and accelerator shell for a Basys 3 / Artix-7 target. It supports the configured block-length range `1..1024`, zero-initialized FIR history, independent sample and successful-commit counts, and physical result-memory commits. It has not yet been FPGA-validated. The normative accelerator behavior is specified in [`docs/ACCELERATOR_CONTRACT_V1.md`](docs/ACCELERATOR_CONTRACT_V1.md).

## Target and architecture

The intended FPGA target is the Digilent Basys 3 using an Artix-7 `XC7A35T-1CPG236C`, represented in the project flow as `xc7a35tcpg236-1`.

The current RTL path is:

```text
PicoRV32
  ├── 16 KiB instruction BRAM (`nexus32_soc`)
  ├── 16 KiB data BRAM (`nexus32_soc`)
  └── accelerator bus bridge (`nexus32_accel_bus`)
        ├── coefficient/sample host ports and result RAM
        └── accelerator CSR shell (`fir_seq_accel`)
              ├── synchronous tap BRAM (`fir_tap_bram`)
              └── runtime selector (`fir_arch_selector`)
                    ├── sequential (`fir_seq_engine`)
                    ├── parallel (`fir_parallel_engine`)
                    └── pipelined (`fir_pipelined_engine`)
```

`LANES` is supported at 4, 8, 16, or 32; the integrated shell defaults to 32. The selector and wrapper serialize the integrated shell to one outstanding operation, so selector/SoC results are functional block-processing results, not standalone throughput or PPA measurements. The direct pipelined engine retains its own ready/valid throughput behavior, but that throughput is not exposed as the serialized shell's top-level throughput.

The integrated shell is a single-buffer block controller. After an accepted START snapshots the configuration, it captures one sample at a time, forms a stable window from the pending sample and accepted-input history, dispatches one engine operation, and waits for the corresponding physical result-memory commit before advancing. `SAMPLE_COUNT` is the configured block length and `RESULT_COUNT` counts only successful commits; `DONE` is asserted after the final commit. Accepted `CTRL.RESET` cancels pending controller state and prevents a pending physical result write, but does not clear BRAM contents. Sample B/ping-pong memory, DMA, streaming interfaces, and AutoArch policy are not implemented in this repository state.

## Current block-processing status

The serialized controller now implements the core multi-sample path described by the contract:

- active tap count, pointers, and block length are snapshotted on START;
- history starts at zero for each run and advances only when an engine input transfer is accepted;
- pending windows remain stable while the engine is not ready;
- output transfer and physical result commit are separate events;
- `RESULT_COUNT` advances only after a successful physical commit;
- a successful block satisfies `BUSY=0`, `DONE=1`, `ERROR=0`, and `RESULT_COUNT=SAMPLE_COUNT`; and
- internal faults leave earlier commits physically present but invalidate the block until RESET.

The detailed 1024-sample matrix, partial-fault checks, and measured pipeline latency are recorded in [`docs/VERIFICATION_CLOSURE.md`](docs/VERIFICATION_CLOSURE.md). This is simulation evidence for the current serialized implementation, not a claim that every V1.0 contract or milestone checklist item is complete.

## Numerical contract

Samples and coefficients are signed 32-bit Q16.16 integers. The RTL makes the arithmetic widths explicit:

1. signed 32×32 multiplication produces a signed 64-bit product;
2. each product is sign-extended to a signed 72-bit Q40.32 term;
3. accumulation and reduction-tree additions remain signed 72-bit;
4. there is no intermediate rounding or saturation;
5. the completed accumulator is shifted arithmetically by 16 (`>>> 16`); and
6. the shifted value is saturated to signed 32-bit range.

The saturation limits are `0x7fffffff` and `0x80000000`. Arithmetic right shift gives the documented floor-toward-negative-infinity behavior for negative values. The reusable arithmetic primitives are `rtl/fir_q16_mac.sv` and `rtl/fir_q16_postprocess.sv`; the executable Python reference is under `golden_model/`.

### Engine behavior

- **Sequential:** `rtl/fir_seq_engine.sv` issues ordered tap requests, accepts ordered valid responses including response bubbles, performs one MAC per valid tap, and reports busy/source-wait cycles through its nominal `cycles_o` counter. It does not provide request backpressure.
- **Parallel:** `rtl/fir_parallel_engine.sv` captures a vector, zero-gates inactive lanes, reduces the signed 72-bit products through a balanced tree, and registers the result. Ready/valid output backpressure holds the result stable.
- **Pipelined:** `rtl/fir_pipelined_engine.sv` registers products, reduction levels, and output processing with elastic ready/valid propagation. Its nominal `cycles_o` is `DEPTH + 1` (`6` at `LANES=32`), not elapsed latency under backpressure.
- **Selector:** `rtl/fir_arch_selector.sv` selects sequential, parallel, or pipelined operation at run time and returns ordered responses. Invalid architecture/tap requests become error responses.

## SoC memory map

The accelerator-facing map is defined by the V1.0 contract:

| Region | Address range | Current role |
|---|---:|---|
| Instruction BRAM | `0x0000_0000–0x0000_3FFF` | PicoRV32 instruction reads |
| Data BRAM | `0x0001_0000–0x0001_3FFF` | PicoRV32 data reads/writes |
| Coefficient BRAM | `0x0002_0000–0x0002_0FFF` | Host read/write while idle; accelerator source while owned |
| Sample BRAM | `0x0002_1000–0x0002_1FFF` | Host read/write while idle; accelerator source while owned |
| Result BRAM | `0x0002_2000–0x0002_2FFF` | Host read-only; accelerator result destination |
| Accelerator CSRs | `0x1000_5000–0x1000_5FFF` | Control, status, counters, and debug registers |

`rtl/nexus32_accel_bus.sv` is a single-master 32-bit valid/ready adapter. Requests are accepted on `req_valid_i && req_ready_o`; while stalled, request fields must remain stable. Each accepted request receives one one-cycle response pulse and there is no response-ready signal.

Accelerator memory and CSR transfers must be aligned 32-bit accesses. Partial writes are rejected. The implemented diagnostic behavior is:

- unmapped pages: `BUS_UNMAPPED`, response data `0xDEAD_BEEF`, `rsp_error=1`;
- mapped malformed/reserved accesses: `BUS_ACCESS`, zero response data, `rsp_error=1`;
- result-memory writes: `RESULT_WRITE_FORBIDDEN`, zero response data, `rsp_error=1`;
- reads of owned coefficient/sample/result memory: `MEM_OWNERSHIP`, response data `0xBAD0_0001`, `rsp_error=1`; and
- owned coefficient/sample writes: `MEM_OWNERSHIP`, zero response data, `rsp_error=1`, with no BRAM side effect.

Host transaction errors are diagnostic events and do not by themselves set accelerator `STATUS.ERROR` or invalidate an otherwise valid run. `bus_fault_sticky_o` and the SoC-level `cpu_bus_fault_o` are external sticky diagnostics cleared only by hardware reset. The CPU bridge preserves diagnostic response data such as `0xBAD0_0001` while completing the CPU handshake.

## Accelerator CSR interface

CSR addresses below are byte offsets from `0x1000_5000`. `CTRL` and `STATUS` use complete-word accesses; `STATUS` and `DBG_STATUS` W1C operations are permitted only while idle according to the contract.

| Offset | Register | Contract meaning | Current implementation note |
|---:|---|---|---|
| `0x00` | `CTRL` | `START` bit 0, `RESET` bit 1, `ARCH_SEL` bits 3:2; RESET wins | Implemented; START while BUSY is a normal no-op |
| `0x04` | `STATUS` | `BUSY`, sticky `DONE`, sticky `ERROR` | Implemented with idle W1C recovery rules |
| `0x08` | `TAP_COUNT` | Configured tap count, validated against the selected build | Implemented |
| `0x0C` | `COEFF_PTR` | Coefficient byte pointer | Implemented |
| `0x10` | `INPUT_PTR` | Input byte pointer | Implemented as the source of the serialized sample block |
| `0x14` | `OUTPUT_PTR` | Result byte pointer | Implemented as the base for per-sample physical commits |
| `0x18` | `CYCLES_TOTAL` | Run-level timing counter | Implemented from START through final commit, or through internal-fault termination |
| `0x1C` | `SAMPLE_COUNT` | Contract: configured block length, `1..1024` | Implemented as an independent configured length and snapshotted on START |
| `0x20` | `COMPUTE_CYCLES` | Contract: first input-transfer to last output-transfer span | Implemented and checked with an independent transfer-edge scoreboard |
| `0x24` | `AUTO_CFG` | Reserved/deferred | Reads return zero; writes are rejected |
| `0x28` | `AUTO_SELECTED` | Reserved/deferred | Reads return zero; writes are rejected |
| `0x2C` | `AUTO_MODEL_ID` | Reserved/deferred | Reads return zero; writes are rejected |
| `0x30` | `DBG_STATUS` | Sticky debug event bits | Bits 0–5 are idle W1C; bits 6–7 are RESET-only |
| `0x34` | `DBG_ADDR` | Address for the latest selected debug event | Implemented with fixed event priority and tie-breaking |
| `0x38` | `DBG_INFO` | Event, direction, and master metadata | Implemented |
| `0x3C` | `RESULT_COUNT` | Contract: successful result-memory commits | Implemented as an independent successful physical-commit counter |
| `0x40` | `CONTRACT_VERSION` | Reserved/deferred | Reads return zero; writes are rejected |
| `0x44` | `BUILD_ID` | Reserved/deferred | Reads return zero; writes are rejected |

The debug event bits are `BUS_UNMAPPED`, `BUS_ACCESS`, `MEM_OWNERSHIP`, `RESULT_WRITE_FORBIDDEN`, `CONFIG_WHILE_BUSY`, `INVALID_CONFIG`, `BRAM_FAULT`, and `ENGINE_ERROR` at bits 0 through 7. When multiple events occur on one edge, all applicable sticky bits are set and metadata follows the contract priority:

```text
ENGINE_ERROR > BRAM_FAULT > INVALID_CONFIG > RESULT_WRITE_FORBIDDEN
> MEM_OWNERSHIP > CONFIG_WHILE_BUSY > BUS_UNMAPPED > BUS_ACCESS
```

For a same-class tie, the lowest address wins, then writes beat reads, then the lowest master ID wins. The CPU/Port-A master ID is 0.

## Known implementation limitations

These remain deliberate, documented limitations; the closure above is not a claim of completed V1.0 hardware validation or of every contract checklist item:

- The integrated wrapper is single-buffered and serializes one outstanding operation. Sample B/ping-pong memory, DMA, streaming interfaces, and AutoArch policy are outside the current implementation.
- The direct pipelined engine's no-stall transfer-edge latency is measured in the closure report; its nominal `cycles_o` field and the measured transfer latency are intentionally distinct. Backpressure stability is checked, but stalled elapsed latency is not a standalone performance claim.
- Selector/SoC measurements include wrapper and serialization overhead and must not be presented as standalone architecture throughput or PPA results.
- UART/GPIO/timer/IRQ/debug-monitor integration and a full SoC bus fabric remain outside the current implementation.
- Vivado synthesis, timing closure, PPA/resource analysis, bitstream validation, board programming, and physical Basys 3 validation have not been completed.

## Repository layout

```text
golden_model/   Bit-exact Python reference model
rtl/            FIR engines, BRAM, accelerator shell, bus adapter, and SoC
firmware/       Bare-metal RV32I assembly and linker/image sources
tests/          Python reference tests and directed RTL/SoC testbenches
scripts/        Firmware, vendor-source, simulation, and characterization flows
vendor/         Pinned PicoRV32 source after provisioning
results/        Generated simulation outputs; do not commit large build artifacts
build/          Generated firmware/build outputs
docs/           Contract, integration notes, status, and provenance
```

The PicoRV32 provisioning script pins upstream revision `ef203c2b0a3fb793280f5114941416c425c5b461`; see [`docs/PICORV32_PIN.md`](docs/PICORV32_PIN.md).

## Setup and firmware prerequisites

The Python reference tests use the standard library only. RTL simulation requires Icarus Verilog; lint checks can use Verilator. SoC simulations also require the pinned PicoRV32 source and an RV32I cross-compiler for firmware generation.

From the repository root:

```bash
bash scripts/vendor_picorv32.sh
bash scripts/build_smoke_firmware.sh
```

`bash scripts/run_soc_smoke.sh all` rebuilds the smoke, multi-architecture, and invalid-fetch firmware images before running its lane sweep. `bash scripts/run_rtl_smoke.sh` runs the SoC portions when the vendored CPU and smoke image are present.

## Verification commands

These are the project-level verification commands currently available:

```bash
python3 -m unittest discover -s tests -v
bash scripts/run_rtl_smoke.sh
bash scripts/run_soc_smoke.sh all
bash scripts/run_verification_closure.sh
```

The Python command checks the signed Q16.16 reference behavior, saturation boundaries, negative arithmetic shift behavior, tap-count validation, and block-model cases. The RTL smoke command runs the arithmetic primitives, sequential engine, synchronous source, tap BRAM, accelerator shell, architecture integration, bus, SoC, invalid-fetch, backpressure, and reset-recovery simulations when their prerequisites are present. The SoC smoke command repeats the bus/SoC suites for `LANES=4, 8, 16, 32`.

The verification-closure command is the canonical pure-RTL gate. It runs the independent 1024-sample block/timing scoreboard, direct pipelined-latency experiments, the 75-case block-processing acceptance suite for `LANES=4, 8, 16, 32`, and the fixed-`LANES=32` block-configuration and configuration-stage acceptance benches. Its generated binaries, per-test status report and logs are written under ignored `results/verification-closure/`; the durable results summary and reproduction details are in [`docs/VERIFICATION_CLOSURE.md`](docs/VERIFICATION_CLOSURE.md). Missing mandatory tools or tests and any compile/simulation failure produce a nonzero gate exit.

## GitHub Actions CI

`.github/workflows/nexus32-ci.yml` runs on pushes and pull requests targeting
`main`, and can also be started manually. On `ubuntu-24.04` it installs
Icarus/VVP, Verilator, the `riscv64-unknown-elf` compiler/binutils, and
provisions the pinned PicoRV32 revision before running the Python, toolchain,
RTL smoke, four-lane SoC smoke, and complete verification-closure checks.
Verilator uses `--Wall --Wno-fatal`: warnings remain visible in the log and
uploaded artifact, while Verilator errors still fail the job.

The principal CI sequence can be reproduced locally after installing the same
tools with:

```bash
export RISCV_CC=riscv64-unknown-elf-gcc
export RISCV_OBJCOPY=riscv64-unknown-elf-objcopy
bash scripts/vendor_picorv32.sh
bash scripts/build_smoke_firmware.sh
python3 -m unittest discover -s tests -v
bash scripts/check_toolchain.sh
bash scripts/run_rtl_smoke.sh
bash scripts/run_soc_smoke.sh all
bash scripts/run_verification_closure.sh
```

CI retains the compact closure status, commands, per-test logs, and Verilator
lint log as workflow artifacts. Passing CI is simulation and toolchain
evidence only; it does not perform Vivado synthesis, timing closure, bitstream
generation, board programming, or physical Basys 3 validation.

Passing these commands means that the exercised reference and RTL simulations completed successfully in the selected simulator/toolchain. It does **not** mean that the design has passed FPGA synthesis, timing closure, implementation, bitstream generation, board programming, power/resource characterization, or physical Basys 3 testing.

## FPGA validation status

The repository currently supports reproducible local modeling, firmware compilation, Icarus simulation, and Verilator lint. Vivado reports, post-route timing, PPA measurements, a validated bitstream, and measurements on a physical Basys 3 are not part of the current evidence. Do not present simulation PASS messages as hardware validation or as standalone architecture PPA results.
