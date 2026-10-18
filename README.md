# NEXUS-32 — PicoRV32 FIR SoC

NEXUS-32 is a PicoRV32-based SoC and a controlled comparison of three direct-form FIR architectures:

- an ordered, one-MAC-at-a-time sequential engine;
- a parallel engine with one multiplier per physical lane and a balanced reduction tree; and
- an elastic registered pipelined reduction tree.

The current integrated design is a simulation-tested control-plane and accelerator shell for a Basys 3 / Artix-7 target. It is not yet a complete block-processing accelerator or FPGA-validated implementation. The normative accelerator behavior is specified in [`docs/ACCELERATOR_CONTRACT_V1.md`](docs/ACCELERATOR_CONTRACT_V1.md).

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

`LANES` is supported at 4, 8, 16, or 32; the integrated shell defaults to 32. The selector serializes the first integrated shell to one outstanding operation, so selector/SoC results are functional smoke results, not standalone throughput or PPA measurements. The direct pipelined engine retains its own ready/valid throughput behavior.

The integrated shell prefetches one complete tap window, dispatches one operation, and emits one result commit. It is a single-buffer design. Sample B/ping-pong memory, DMA, streaming block processing, and AutoArch are not implemented in this repository state.

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
| `0x10` | `INPUT_PTR` | Input byte pointer | Implemented for the single prefetched window |
| `0x14` | `OUTPUT_PTR` | Result byte pointer | Implemented for the single result commit |
| `0x18` | `CYCLES_TOTAL` | Run-level timing counter | Published, but exact contract edge semantics remain incomplete |
| `0x1C` | `SAMPLE_COUNT` | Contract: configured block length, `1..1024` | Not separately implemented; current writes are rejected, readback uses the legacy successful-commit counter, and configured block iteration is absent |
| `0x20` | `COMPUTE_CYCLES` | Contract: first input-transfer to last output-transfer span | Published, but current shell timing is not yet the complete edge-defined contract |
| `0x24` | `AUTO_CFG` | Reserved/deferred | Reads return zero; writes are rejected |
| `0x28` | `AUTO_SELECTED` | Reserved/deferred | Reads return zero; writes are rejected |
| `0x2C` | `AUTO_MODEL_ID` | Reserved/deferred | Reads return zero; writes are rejected |
| `0x30` | `DBG_STATUS` | Sticky debug event bits | Bits 0–5 are idle W1C; bits 6–7 are RESET-only |
| `0x34` | `DBG_ADDR` | Address for the latest selected debug event | Implemented with fixed event priority and tie-breaking |
| `0x38` | `DBG_INFO` | Event, direction, and master metadata | Implemented |
| `0x3C` | `RESULT_COUNT` | Contract: successful result-memory commits | Currently aliases the same legacy sample/commit counter as `SAMPLE_COUNT` |
| `0x40` | `CONTRACT_VERSION` | Reserved/deferred | Reads return zero; writes are rejected |
| `0x44` | `BUILD_ID` | Reserved/deferred | Reads return zero; writes are rejected |

The debug event bits are `BUS_UNMAPPED`, `BUS_ACCESS`, `MEM_OWNERSHIP`, `RESULT_WRITE_FORBIDDEN`, `CONFIG_WHILE_BUSY`, `INVALID_CONFIG`, `BRAM_FAULT`, and `ENGINE_ERROR` at bits 0 through 7. When multiple events occur on one edge, all applicable sticky bits are set and metadata follows the contract priority:

```text
ENGINE_ERROR > BRAM_FAULT > INVALID_CONFIG > RESULT_WRITE_FORBIDDEN
> MEM_OWNERSHIP > CONFIG_WHILE_BUSY > BUS_UNMAPPED > BUS_ACCESS
```

For a same-class tie, the lowest address wins, then writes beat reads, then the lowest master ID wins. The CPU/Port-A master ID is 0.

## Known implementation limitations

These are deliberate, documented limitations; they are not claims of completed V1.0 block behavior:

- `SAMPLE_COUNT` is not yet a separately implemented configured block length. The current shell executes one prefetched window rather than a configured sample block.
- `RESULT_COUNT` still shares the legacy sample/commit counter; it is not yet an independent counter for a multi-result block.
- Complete block iteration, pending-sample capture, sample history, and atomic window advancement on engine input acceptance are not implemented.
- Output transfer and result-memory commit are not yet modeled as independent events for a full block, so the complete result-validity predicate is not available for multi-sample processing.
- Some run-level timing semantics remain incomplete. In particular, the current shell counters are not yet the full `e_start`/`e_done` and first-input/last-output transfer-edge definitions in §8 of the contract.
- The pipelined engine's documented edge-to-edge input-accept to output-transfer latency remains **unverified**. Its `cycles_o` field is nominal no-stall pipeline depth, not proof of measured waveform latency.
- Sample B, DMA, streaming interfaces, AutoArch policy, UART/GPIO/timer/IRQ/debug-monitor integration, and a full SoC bus fabric are outside the current implementation.
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
```

The Python command checks the signed Q16.16 reference behavior, saturation boundaries, negative arithmetic shift behavior, tap-count validation, and block-model cases. The RTL smoke command runs the arithmetic primitives, sequential engine, synchronous source, tap BRAM, accelerator shell, architecture integration, bus, SoC, invalid-fetch, backpressure, and reset-recovery simulations when their prerequisites are present. The SoC smoke command repeats the bus/SoC suites for `LANES=4, 8, 16, 32`.

Passing these commands means that the exercised reference and RTL simulations completed successfully in the selected simulator/toolchain. It does **not** mean that the design has passed FPGA synthesis, timing closure, implementation, bitstream generation, board programming, power/resource characterization, or physical Basys 3 testing.

## FPGA validation status

The repository currently supports reproducible local modeling, firmware compilation, Icarus simulation, and Verilator lint. Vivado reports, post-route timing, PPA measurements, a validated bitstream, and measurements on a physical Basys 3 are not part of the current evidence. Do not present simulation PASS messages as hardware validation or as standalone architecture PPA results.
