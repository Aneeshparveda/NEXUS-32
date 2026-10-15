# NEXUS-32 — Starter Repository

**Status:** initial implementation scaffold; not yet G0-approved or a complete SoC.

NEXUS-32 is a controlled, bit-exact comparison of sequential, parallel, and pipelined direct-form FIR engines integrated into a PicoRV32-based SoC for a Basys 3 / Artix-7 target.

## Frozen numerical contract

- Samples and coefficients are signed Q16.16 values stored as signed 32-bit integers.
- Each product is signed 32×32 → 64 bit.
- Each product is sign-extended into a signed 72-bit Q40.32 accumulator.
- There is no intermediate rounding or saturation.
- The final result uses arithmetic right shift by 16 (`>>> 16` in RTL), equivalent to floor toward negative infinity for negative values.
- The shifted result is saturated to signed 32-bit range.
- Baseline block mode begins with zero history. For output `y[n]`, `y[n] = sat32((sum(x[n-k] * h[k])) >>> 16)`, with unavailable pre-block samples treated as zero.
- Supported mathematical reference tap count is 1–32; the initial primary spatial experiment set is 4, 8, and 16 taps. Other configurations remain conditional research cases.

This Python reference is intended as a clear executable contract. Before using it as research evidence, keep the RTL/golden model agreement tests, an independently implemented second reference, and mutation checks in the verification plan.

## Repository layout

```text
golden_model/   Bit-exact integer reference model
tests/          Unit tests for the numerical contract
rtl/            RTL modules
firmware/       Bare-metal RISC-V firmware (to be added)
scripts/        Local toolchain smoke tests
results/        Raw and derived experiment outputs (never commit large generated builds)
docs/           Architecture decisions, risk register, gate evidence
```

## First milestone: install a supported Python and run the model

On Apple Silicon with Homebrew:

```bash
brew install python@3.13
cd NEXUS-32-starter
/opt/homebrew/bin/python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m unittest discover -s tests -v
```

Use the explicit `python3.13` path for this project. Your current shell's `python3` may still resolve to macOS Python 3.9.6, while Homebrew's unversioned `python3` currently resolves to a newer Python.

## Toolchain smoke checks

```bash
verilator --version
iverilog -V 2>&1 | head -n 2
riscv64-elf-gcc --version | head -n 1
riscv64-elf-gcc -march=rv32i -mabi=ilp32 -dM -E -x c /dev/null | grep -E '__riscv_xlen|__riscv_mul'
```

An RV32I compiler smoke test is also available:

```bash
bash scripts/check_toolchain.sh
```

## Vivado note

Use this Mac for editing, Python modelling, Verilator/Icarus simulation, firmware compilation, and data analysis. FPGA synthesis, implementation, board programming, and vendor timing/resource reports should run in a supported Vivado environment. Do not treat open-source synthesis estimates as Vivado implementation results.

## Sequential FIR engine milestone

The sequential kernel is `rtl/fir_seq_engine.sv`. It validates 1–32 taps, issues ordered tap reads, accumulates valid responses in a signed 72-bit Q40.32 accumulator, then applies one final arithmetic shift and signed 32-bit saturation. `done_o` and `error_o` are one-cycle pulses; starts while busy are ignored.

### Tap-source contract

- `tap_req_o` plus `tap_addr_o` issue ordered reads at up to one request per clock.
- `tap_valid_i` identifies a response. Samples and coefficients must match the request order.
- A combinational tap mux can tie `tap_valid_i` high and select the words using `tap_addr_o`.
- A one-cycle synchronous BRAM can register the read data and `tap_valid_i` from `tap_req_o`/`tap_addr_o`. The first response arrives one cycle after the first request.
- This engine does not apply request backpressure; the source must accept one read request each cycle while `tap_req_o` is high.
- `cycles_o` reports busy cycles including source latency and valid-response gaps; it saturates at 65535.

Run the arithmetic, combinational-source, and synchronous-source directed testbenches with:

```bash
bash scripts/run_rtl_smoke.sh
```

**Important:** this is still a standalone kernel. Sample-history construction, memory ownership, accelerator CSRs, system bus, PicoRV32 integration, and watchdog behavior remain to be implemented. Do not connect unverified modules to the SoC.

## First integrated accelerator shell milestone

`rtl/fir_seq_accel.sv` is an initial single-buffer shell combining the sequential engine and synchronous tap BRAM with a small local CSR request/response interface. CSR addresses are **offsets** within the accelerator register window; a future SoC bus adapter will translate `0x10005000 + offset`. The shell's read responses are registered one-cycle pulses with no response backpressure. Requests use full-word writes only.

CSR offsets: `CTRL 0x00`, `STATUS 0x04`, `TAP_COUNT 0x08`, `COEFF_PTR 0x0c`, `INPUT_PTR 0x10`, `OUTPUT_PTR 0x14`, `CYCLES_TOTAL 0x18`, `SAMPLE_COUNT 0x1c`, and `COMPUTE_CYCLES 0x20`. START is bit 0 of CTRL. STATUS has BUSY/DONE-sticky/ERROR-sticky in bits 0/1/2; DONE and ERROR are write-one-to-clear while idle.

The controller validates the entire byte pointer, 4-byte alignment, tap count 1–32, and end-exclusive spans before issuing START. This first version accepts coefficients in `0x20000–0x20fff`, samples in sample bank A `0x21000–0x21fff`, and one result word in `0x22000–0x22fff`. It does not yet implement sample bank B, multi-sample block iteration, DMA, the full SoC bus, or the PicoRV32 integration.

The testbench host-write ports accept 10-bit local word offsets into the sample/coefficient banks. Writes are blocked while the run owns the banks, including the accepted START edge. Any blocked write raises a sticky ownership fault and causes the active job's result to be discarded. A successful result is emitted as a one-cycle `result_commit_o` pulse plus full byte address and data; a future memory/bus adapter must commit that pulse to result RAM.

Run `bash scripts/run_rtl_smoke.sh` to execute the five RTL testbenches currently covering the arithmetic primitives, sequential engine, synchronous tap alignment, BRAM, and integrated accelerator shell. The owner reported those suites passing on the Mac on 2026-10-15. No Vivado BRAM inference, timing, or hardware results are claimed yet.

## System bus adapter milestone

`rtl/nexus32_accel_bus.sv` adds a single-master, 32-bit word-access valid/ready adapter around the CSR shell, sample/coefficient memories, and result memory. Supported pages are:

| Address range | Access | Behavior |
|---|---|---|
| `0x00020000–0x00020fff` | Read/write | Coefficient RAM |
| `0x00021000–0x00021fff` | Read/write | Sample bank A |
| `0x00022000–0x00022fff` | Read only | Result RAM, written by accelerator commit |
| `0x10005000–0x10005fff` | Read/write CSRs | Accelerator register window |

All transfers must be 32-bit aligned. Memory writes require all four byte strobes. Unmapped pages, partial writes, misaligned transfers, and host writes to result RAM return an error response. A sticky bus-fault output records errors. Host writes to sample/coefficient RAM during accelerator ownership are rejected and propagate into the accelerator ownership-fault mechanism.

Bus requests are accepted at a rising edge when `req_valid_i && req_ready_o`. While valid is asserted and ready is low, the master must keep request fields stable. Every accepted transfer generates a one-cycle `rsp_valid_o` pulse; there is no response-ready input, so the master must always observe each response pulse. This adapter is not a full SoC bus fabric: instruction/data SRAM, Sample B/ping-pong, DMA, CPU arbitration, debug MMIO, and PicoRV32 integration remain future work.

The new testbench `tests/rtl/tb_nexus32_accel_bus.sv` exercises memory writes/readback, end-to-end four-tap filtering, result-memory commit/readback, address/protection errors, sticky fault reporting, and write rejection during bank ownership. This testbench is delivered for owner-side validation; do not mark this milestone passed until `bash scripts/run_rtl_smoke.sh` passes on the Mac. Vivado BRAM inference and timing remain unverified.
