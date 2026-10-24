# NEXUS-32 Accelerator Contract V1.0

**Status:** Approved in principle for controlled Batch 1 documentation; normative source for subsequent accelerator implementation after the next implementation gate.
**Scope:** Accelerator numerical behavior, memory/CSR interface, ownership safety, error recovery, block processing, cycle accounting, and characterization methodology.
**Batch boundary:** This document-only batch does not modify RTL, firmware, tests, build scripts, Vivado files, or toolchain configuration.

## 0. Authority, provenance, and terminology

This document is the NEXUS-32 accelerator Contract V1.0.  It records the approved
contract package and the clarifications accepted by the project leader.  The
contract is the source of truth for later implementation; existing RTL is not
treated as an implicit contract where it disagrees with this document.

The candidate authority reviewed for this contract is the external document:

```text
NEXUS-32 — FINAL V2.2 MASTER ENGINEERING PLAN
Version: 2.2 — Technical-closure, execution-hardened, and research-differentiation baseline
Date: 2026-10-09
Revision basis: V2.1 + execution review + technical red-team review + research differentiation review
Status: Engineering baseline approved for execution
```

The V2.2 candidate is supplied outside this repository and is not committed at
the repository base SHA.  No commit SHA is assigned to that specification.  V2.2
is the controlling predecessor; this V1.0 document makes the approved
accelerator-level decisions explicit, including decisions that are additions or
clarifications to the current repository implementation.

The following are explicit V1.0 decisions or clarifications and are not claimed
as verbatim V2.2 register text: `RESULT_COUNT` at `0x3C`; reserved/deferred
`CONTRACT_VERSION` and `BUILD_ID` behavior; the exact `DBG_STATUS` bit
assignments; zero response data for forbidden writes; preservation of the
protected-read sentinel through the CPU bridge; non-fatal host ownership and
configuration errors; the W1C/recovery distinction for invalid configuration
versus internal faults; the idle-only debug-event W1C policy; the deterministic
same-edge debug metadata priority; the normal completion response for a
well-formed but preflight-invalid START; the reset-cleared `cpu_bus_fault_o`
diagnostic; and the pending-sample/error counter rules.  V2.2 provides the
underlying architecture direction, while this approved V1.0 document is
authoritative for those clarified details.

The words **shall**, **must**, and **required** are normative.  **May** denotes a
permitted implementation choice that does not change observable contract
behavior.  **Diagnostic only** means that a value may describe a partial or
failed run but must not be used as evidence of a valid completed block.

## 1. Contract invariants

The implementation shall preserve all of the following invariants:

1. The numerical result is bit-exact across Sequential, Parallel, and Pipelined
   engines for the same accepted input window and tap count.
2. An accepted engine input has exactly one ordered output response unless the
   run is reset or terminated by an internal fault; an output response is held
   stable under downstream backpressure.
3. Accelerator-owned coefficient, sample, and result memory cannot be modified
   or silently observed by a host transaction while the run owns those regions.
4. Host transaction failures are observable but do not become accelerator
   execution failures unless the contract explicitly identifies an internal
   fault.
5. `RESULT_COUNT` counts successful result-memory commits only.
6. A result block is valid only after the complete success predicate in §6.4 is
   true; physical contents left by an earlier, partial, or failed run are not a
   valid block.

## 2. Numerical and engine contract

### 2.1 Fixed-point representation

Samples and coefficients are signed 32-bit Q16.16 values.  For every active tap:

```text
signed 32-bit sample × signed 32-bit coefficient
    -> signed 64-bit Q32.32 product
    -> explicit sign extension to signed 72-bit Q40.32 term
```

Every accumulator update and every reduction-tree node is:

```text
signed 72-bit + signed 72-bit -> signed 72-bit
```

The implementation shall not rely on implicit SystemVerilog expression sizing
to establish these widths.  There is no intermediate rounding and no
intermediate saturation.  After the complete 72-bit accumulation:

```text
shifted = accumulator >>> 16
```

The shift is arithmetic.  The shifted signed value is saturated to the signed
32-bit range:

```text
shifted >  0x7fffffff -> 0x7fffffff
shifted < -0x80000000 -> 0x80000000
otherwise             -> shifted[31:0]
```

Discarding fractional bits therefore has deterministic arithmetic-floor
behavior for negative values.  No architecture may introduce a different
rounding or saturation point.

### 2.2 Window and history meaning

For accepted sample index `n`, the logical history contains exactly `TAP_COUNT-1`
entries.  For `TAP_COUNT=1`, the history is empty and the engine window contains
only the current sample.  For `TAP_COUNT>=2`, the engine window is ordered as:

```text
window[n] = [x[n], history_before[n][0], history_before[n][1], ...]
```

At block start, all logical history entries are zero.  Unavailable pre-block
samples are therefore treated as zero.  The detailed capture, transfer, and
history-update ordering is normative in §7; in particular, history is not
advanced at sample capture, output transfer, or result commit.

### 2.3 Ready/valid transfer contract

```text
input_transfer  = engine_in_valid  && engine_in_ready
output_transfer = engine_out_valid && engine_out_ready
```

For every accepted input, the corresponding output remains ordered with respect
to prior accepted inputs.  While `engine_out_valid=1` and
`engine_out_ready=0`, the engine shall hold `engine_out_valid`, result data,
error indication, and any associated response metadata stable.  Backpressure may
stall pipeline movement but may not duplicate, drop, or reorder a transaction.

Reset clears valid/error state and flushes in-flight engine transactions.  A
future implementation may use one or more accepted windows in flight; this
contract does not require a particular microarchitecture or impose a
single-sample pipeline schedule.

## 3. SoC memory map and access permissions

The accelerator-facing memory map is:

| Region | Address range | Size | Host/Port-A access while idle | Accelerator/Port-B role |
|---|---:|---:|---|---|
| Instruction BRAM | `0x0000_0000–0x0000_3FFF` | 16 KiB | CPU instruction reads | CPU-local |
| Data BRAM | `0x0001_0000–0x0001_3FFF` | 16 KiB | CPU data reads/writes | CPU-local |
| Coefficient BRAM | `0x0002_0000–0x0002_0FFF` | 4 KiB | Read/write before ownership | Coefficient source |
| Sample BRAM | `0x0002_1000–0x0002_1FFF` | 4 KiB | Read/write before ownership | Input source |
| Result BRAM | `0x0002_2000–0x0002_2FFF` | 4 KiB | Read-only; host writes forbidden in every state | Result destination |
| Accelerator CSRs | `0x1000_5000–0x1000_5FFF` | 4 KiB | CSR rules in §4 | Controller |

The V1.0 core contract does not claim Sample B, DMA, UART, GPIO, timer, IRQ,
debug-monitor, or AutoArch implementation.  Those address regions remain
outside this batch and must not be inferred from the presence of a planned V2.2
address-map entry.

### 3.1 Alignment and transfer rules

All accelerator memory and CSR transfers are 32-bit word transfers and require
`addr[1:0] == 2'b00`.  Address-page decoding occurs before transfer-format
validation:

1. An address outside every mapped page is `BUS_UNMAPPED`, returns
   `0xDEAD_BEEF`, asserts `rsp_error=1`, and performs no mapped side effect.
   This classification wins over misalignment or byte-strobe properties on an
   otherwise unmapped address.
2. A mapped but malformed transfer—misaligned address, partial write, or
   reserved/unsupported CSR offset—is `BUS_ACCESS`, returns zero data, asserts
   `rsp_error=1`, and performs no mapped side effect.
3. A decoded result-region write is always `RESULT_WRITE_FORBIDDEN`, including
   while idle; this specific event takes priority over generic `BUS_ACCESS` and
   `MEM_OWNERSHIP` and returns zero data with `rsp_error=1`.
4. A well-formed mapped access to an owned coefficient, sample, or result region
   is `MEM_OWNERSHIP` and uses the protection responses in §5.2.

The event priority above is also the classification priority when a request
could otherwise match more than one category.  All classified errors perform no
mapped side effect.

The valid/ready bus accepts a request on a rising edge when `req_valid &&
req_ready`.  While `req_valid=1` and `req_ready=0`, the master shall hold address,
direction, write data, and byte strobes stable.  Every accepted request receives
one completion; the current integration has no response-backpressure input.

### 3.2 Configuration range validation

Before an accepted run can access accelerator Port B, the controller shall
validate all configuration using widened, overflow-safe arithmetic:

```text
1 <= TAP_COUNT    <= MAX_TAPS
1 <= SAMPLE_COUNT <= 1024
ARCH_SEL is legal for the selected build
all pointers are 4-byte aligned
COEFF_PTR + TAP_COUNT    * 4 stays inside coefficient BRAM
INPUT_PTR + SAMPLE_COUNT * 4 stays inside sample BRAM
OUTPUT_PTR + SAMPLE_COUNT * 4 stays inside result BRAM
no addition or multiplication wraps the pointer arithmetic
```

The validation must use a widened representation or an equivalent subtraction
check; it must not rely on wrapped 32-bit end addresses.  `MAX_TAPS` is the
compile-time maximum for the selected engine build.  The supported current
physical lane builds are 4, 8, 16, and 32.

## 4. Accelerator CSR contract

The CSR base is `0x1000_5000`.  The reset values below are architectural reset
values, including a synchronous `CTRL.RESET`; resetting the controller does not
physically clear result BRAM.

| Offset | Register | Reset | Access | Normative semantics |
|---:|---|---:|---|---|
| `0x00` | `CTRL` | `0x0000_0000` | W | Complete-word command: `START` bit 0, `RESET` bit 1, `ARCH_SEL` bits `[3:2]`; bits `[31:4]` must be zero. Reads return zero. |
| `0x04` | `STATUS` | `0x0000_0000` | R/W1C | Bit 0 `BUSY`, bit 1 sticky `DONE`, bit 2 sticky `ERROR`. `DONE` and recoverable `ERROR` are W1C while idle. |
| `0x08` | `TAP_COUNT` | `0x0000_0000` | RW | Configured tap count; validated as `1..MAX_TAPS` at START. |
| `0x0C` | `COEFF_PTR` | `0x0002_0000` | RW | Byte pointer to the coefficient block. |
| `0x10` | `INPUT_PTR` | `0x0002_1000` | RW | Byte pointer to the input sample block. |
| `0x14` | `OUTPUT_PTR` | `0x0002_2000` | RW | Byte pointer to the result block. |
| `0x18` | `CYCLES_TOTAL` | `0x0000_0000` | R | Run-level elapsed counter, defined in §8. |
| `0x1C` | `SAMPLE_COUNT` | `0x0000_0000` | RW | Configured block length, `1..1024`; it is not a result counter. |
| `0x20` | `COMPUTE_CYCLES` | `0x0000_0000` | R | Run-level engine transfer span, defined in §8. |
| `0x24` | `AUTO_CFG` | `0x0000_0000` | Reserved | Unimplemented in V1.0: reads return zero; writes complete with `rsp_error=1` and `BUS_ACCESS`. |
| `0x28` | `AUTO_SELECTED` | `0x0000_0000` | Reserved | Unimplemented in V1.0: reads return zero; writes complete with `rsp_error=1` and `BUS_ACCESS`. |
| `0x2C` | `AUTO_MODEL_ID` | `0x0000_0000` | Reserved | Unimplemented in V1.0: reads return zero; writes complete with `rsp_error=1` and `BUS_ACCESS`. |
| `0x30` | `DBG_STATUS` | `0x0000_0000` | R/W1C | Sticky debug events in §5. Bits 0–5 are W1C only while idle; `BRAM_FAULT` and `ENGINE_ERROR` require RESET. |
| `0x34` | `DBG_ADDR` | `0x0000_0000` | R | Address associated with the most recently latched bus/debug event. |
| `0x38` | `DBG_INFO` | `0x0000_0000` | R | Encoded master, direction, and event information for the most recently latched event. |
| `0x3C` | `RESULT_COUNT` | `0x0000_0000` | R | Number of successful result-memory commits in the current run. |
| `0x40` | `CONTRACT_VERSION` | `0x0000_0000` | Reserved/deferred | Reads return zero; writes complete with `rsp_error=1` and `BUS_ACCESS`. |
| `0x44` | `BUILD_ID` | `0x0000_0000` | Reserved/deferred | Reads return zero; writes complete with `rsp_error=1` and `BUS_ACCESS`. |

Unlisted offsets are reserved and use the same no-side-effect `BUS_ACCESS`
behavior.  Reserved-register accesses do not start, stop, or alter a run and do
not change the architectural execution status.

### 4.1 CTRL commands

`CTRL` uses complete-word writes.  The controlled fixed-architecture encoding is:

```text
bit 0       START
bit 1       RESET
bits [3:2]  00 = Sequential, 01 = Parallel, 10 = Pipelined, 11 = reserved
bits [31:4] must be zero
```

`RESET` has priority over `START`.  A valid START snapshots the configuration,
clears `DONE`, clears the run counters and `RESULT_COUNT`, and acquires the
coefficient, sample, and result ownership reservation on the same accepting
edge.  A valid START is accepted only when the controller is idle, the
configuration passes validation, and `STATUS.ERROR` is clear.

START written while `BUSY=1` is a normal-completion no-op: it does not change
the active operation, configuration, counters, result count, status bits, or
debug events.  It must not be converted into a new execution error.

While `BUSY=1`, configuration writes are rejected without modifying the active
snapshot.  They set `CONFIG_WHILE_BUSY`, return a host transaction error, and do
not set `STATUS.ERROR` or invalidate the active run.  A new run is not accepted
while `STATUS.ERROR` remains set; the existing error must first be cleared by
the permitted recovery action.

### 4.2 STATUS and reset

On accepted START:

```text
BUSY  = 1
DONE  = 0
ERROR = 0
RESULT_COUNT = 0
CYCLES_TOTAL = 0
COMPUTE_CYCLES = 0
```

On successful final result commit, the controller clears `BUSY`, sets sticky
`DONE`, leaves `ERROR=0`, and exposes the final counters.  On an internal run
failure, the controller clears `BUSY`, clears `DONE`, and sets sticky `ERROR`;
the partial result block is invalid.

Hardware reset and `CTRL.RESET` clear controller state, ownership, `BUSY`,
`DONE`, `ERROR`, debug events, counters, pending block state, and
`RESULT_COUNT`.  `CTRL.RESET` responds as a completed command.  Reset does not
physically clear coefficient, sample, or result BRAM; any result contents from
before reset are invalid until a subsequent run satisfies the success predicate.

## 5. Ownership, protection, and host response contract

### 5.1 Ownership reservation

An accepted valid START reserves coefficient, sample, and result memory for the
accelerator on the START accepting edge, before `BUSY` is visible in the next
state.  This edge-sensitive reservation prevents a simultaneous host write from
slipping through.  Ownership is released by successful completion, internal
error termination, or RESET.

### 5.2 Required host behavior

The following rules apply to Port-A/host accesses to accelerator-owned memory:

| Host request | Condition | Response data | Error/event | BRAM side effect | Active run |
|---|---|---:|---|---|---|
| Coefficient/sample/result read | Region owned by accelerator | `0xBAD0_0001` | `rsp_error=1`, sticky `MEM_OWNERSHIP` | None | Continues |
| Coefficient/sample write | Region owned by accelerator | `0x0000_0000` | `rsp_error=1`, sticky `MEM_OWNERSHIP` | None | Continues |
| Result write | Any state, including idle | `0x0000_0000` | `rsp_error=1`, sticky `RESULT_WRITE_FORBIDDEN` | None | Continues |

The result-write case is distinct from `MEM_OWNERSHIP` even when the controller
is busy.  It shall never be reclassified as an ownership event.  A forbidden
host access is a completed host transaction; it is not a dropped request.

The unmapped-page diagnostic response is `0xDEAD_BEEF` with `rsp_error=1` and
sticky `BUS_UNMAPPED`.  A mapped but misaligned, partial, reserved, or otherwise
malformed transaction returns zero data with `rsp_error=1` and sticky
`BUS_ACCESS`, unless the more-specific result-write rule above applies.  An
unmapped address is never reclassified as `BUS_ACCESS` merely because its
alignment or byte strobes are also invalid.

The bus-level sticky fault output and the SoC `cpu_bus_fault_o` are external
diagnostics for errored host transactions.  They do not imply `STATUS.ERROR`, do
not abort a valid run, and are not a claim that PicoRV32 takes a native bus-error
trap.  The CPU bridge shall preserve `accel_rsp_rdata`, including
`0xBAD0_0001`, while asserting the normal CPU response/ready handshake.

`bus_fault_sticky_o` and `cpu_bus_fault_o` are cleared only by the external
hardware reset `rst_i`.  They are not cleared by `CTRL.RESET`, `STATUS` W1C,
`DBG_STATUS` W1C, or a later successful transaction; no new CSR is introduced
for these external diagnostics.  A host transaction with `rsp_error=1` sets the
corresponding sticky diagnostic.  A well-formed preflight-invalid START uses the
normal completion response defined in §6.1 and therefore does not set
`cpu_bus_fault_o` merely because it sets `STATUS.ERROR`.

### 5.3 Debug events

`DBG_STATUS` bits are:

| Bit | Event | Meaning |
|---:|---|---|
| 0 | `BUS_UNMAPPED` | Accepted transaction addressed no mapped region. |
| 1 | `BUS_ACCESS` | Misalignment, partial write, reserved CSR, or other generic access violation. |
| 2 | `MEM_OWNERSHIP` | Host accessed a coefficient/sample/result region owned by the accelerator. |
| 3 | `RESULT_WRITE_FORBIDDEN` | Host attempted a result-memory write in any state. |
| 4 | `CONFIG_WHILE_BUSY` | Host attempted a configuration write while a run was active. |
| 5 | `INVALID_CONFIG` | START failed preflight validation. |
| 6 | `BRAM_FAULT` | Internal BRAM range/collision fault. |
| 7 | `ENGINE_ERROR` | Internal engine failure or error termination. |

Events are sticky until their permitted clearing action.  `BUS_UNMAPPED`,
`BUS_ACCESS`, `MEM_OWNERSHIP`, `RESULT_WRITE_FORBIDDEN`, `CONFIG_WHILE_BUSY`,
and `INVALID_CONFIG` (bits 0–5) may be cleared by a W1C write to `DBG_STATUS`
only while `BUSY=0`.  A `DBG_STATUS` W1C write while busy is rejected as
`BUS_ACCESS`, clears no bit, does not alter the active run, and does not clear
`STATUS.ERROR`; it returns zero response data with `rsp_error=1`.  `BRAM_FAULT`
and `ENGINE_ERROR` (bits 6–7) are RESET-only;
writing one to those bits has no clearing effect.  Clearing
`DBG_STATUS.INVALID_CONFIG` does not clear `STATUS.ERROR`; the recoverable
status bit requires its separate idle W1C operation.  No debug W1C operation can
clear `STATUS.ERROR` for a RESET-only BRAM or engine fault.

When more than one distinct event is observed on the same rising edge, every
applicable event bit is set in `DBG_STATUS`.  `DBG_ADDR` and `DBG_INFO` describe
the highest-priority event using this fixed order (highest first):

```text
ENGINE_ERROR
BRAM_FAULT
INVALID_CONFIG
RESULT_WRITE_FORBIDDEN
MEM_OWNERSHIP
CONFIG_WHILE_BUSY
BUS_UNMAPPED
BUS_ACCESS
```

For multiple instances of one event class on the same edge, the lowest
offending address wins; if addresses are equal, writes win over reads; if the
direction is also equal, the lowest encoded master ID wins.  The V1.0 CPU/Port-A
master has ID `0`; future master IDs are assigned in increasing numeric order.
A newly observed event wins over a same-edge W1C clear for its bit.  These
metadata-selection rules do not suppress any other sticky event bit.  Clearing
a debug event does not clear `STATUS.ERROR`, release ownership, alter counters,
or change an active run.

## 6. Error and recovery contract

### 6.1 Preflight invalid configuration

An invalid START is rejected before accelerator Port-B memory access and before
ownership is acquired.  Examples include an invalid tap count or block length,
an illegal architecture selection, misaligned pointer, out-of-range span, or
pointer arithmetic overflow.

V2.2 defines the resulting controller state for invalid configuration but does
not define a separate `rsp_error` value for a well-formed command that fails
semantic preflight.  V1.0 therefore makes the following bus distinction
explicit: an aligned, complete-word START write is accepted and completes with
`rsp_error=0` and zero write-response data, while the controller reports the
command rejection through `STATUS.ERROR=1` and `DBG_STATUS.INVALID_CONFIG=1`.
This is not a malformed bus transaction, does not set `BUS_ACCESS`, and does
not set `cpu_bus_fault_o`.  Misaligned, partial, reserved, or otherwise
malformed START/CSR writes remain `BUS_ACCESS` with `rsp_error=1` under §3.1.

The required result is:

```text
BUSY = 0
DONE = 0
ERROR = 1
DBG_STATUS.INVALID_CONFIG = 1
CYCLES_TOTAL = 0
COMPUTE_CYCLES = 0
RESULT_COUNT = 0
no accelerator memory access
no ownership acquisition
no physical result-memory change
```

`INVALID_CONFIG` is recoverable.  After the configuration is corrected, the
projected implementation may clear `STATUS.ERROR` with the idle W1C operation;
the previous invalid result remains invalid.  A new START is not accepted while
the error remains set.  Clearing the `INVALID_CONFIG` debug bit and clearing the
recoverable `STATUS.ERROR` bit are separate idle operations.

### 6.2 Internal BRAM and engine faults

An internal BRAM range/collision fault is `BRAM_FAULT`.  An engine-reported or
controller-detected compute failure is `ENGINE_ERROR`.  Either fault terminates
the active run, prevents a final successful completion, and produces:

```text
BUSY = 0
DONE = 0
ERROR = 1
```

Partial commits, if any, remain physically present but the complete block is
invalid.  `STATUS.ERROR` for these internal faults is not cleared by W1C;
RESET is required.  RESET also clears the pending sample/window and releases
ownership without clearing result BRAM.

### 6.3 Host failures are not execution failures

`BUS_UNMAPPED`, `BUS_ACCESS`, `MEM_OWNERSHIP`, `RESULT_WRITE_FORBIDDEN`, and
`CONFIG_WHILE_BUSY` are host/debug events.  They may assert the host response
error and external sticky bus-fault diagnostic, but they do not set
`STATUS.ERROR`, do not make a valid active run invalid, and do not alter its
counter definitions.  A protected memory request has no BRAM side effect.

### 6.4 Result validity and firmware success

A result block is valid only when all of the following are true:

```text
BUSY == 0
DONE == 1
ERROR == 0
RESULT_COUNT == SAMPLE_COUNT
```

Firmware shall use exactly this predicate, not the presence of nonzero words in
result BRAM.  Result words from a prior run, a partial run, an invalid START, an
internal error, or a RESET remain physically readable when host access is
allowed but shall be treated as stale/invalid until a later run satisfies the
predicate.

## 7. Normative block-processing contract

Let `M = SAMPLE_COUNT`, let `T = TAP_COUNT`, and let `n` range from zero through
`M-1`.  History is initialized to zero for each accepted run.  The controller
shall implement the following sequence for each sample.

### 7.1 Capture a pending sample

At `e_sample[n]`, after the synchronous sample-memory response is available, the
controller captures the new sample into an internal pending-sample register:

```text
pending_sample_q <= sample_memory_data
pending_valid_q  <= 1
```

This capture does not advance history, transfer an engine input, or increment
`RESULT_COUNT`.

### 7.2 Form a stable pending window

The window for sample `n` is formed from the pending sample and the history state
before sample `n` is accepted.  The all-tap-count definition is:

```text
if T == 1:
    window[n] = [pending_sample_q]
    history    = []
else:
    window[n] = [pending_sample_q,
                 history_q[0], history_q[1], ..., history_q[T-2]]
```

The complete window and the pending sample are stable for as long as the engine
has not accepted the input.

### 7.3 Accept the window and advance history atomically

On the same rising edge where:

```text
engine_in_valid && engine_in_ready
```

is true, the engine accepts the stable window and the controller atomically
advances history for the next accepted input:

```text
engine accepts [pending_sample_q, old history]
if T == 1:
    history_next = []
else:
    history_next[0] = pending_sample_q
    history_next[k] = history_q[k-1]   for 1 <= k <= T-2
history_q       <= history_next
pending_valid_q <= 0
```

The engine therefore sees the pre-transfer history for sample `n`, while the
new history becomes the pre-transfer history for sample `n+1`.  History advances
on input acceptance only; it does not advance at sample capture, window
formation, output transfer, or result-memory commit.

### 7.4 Stall behavior

If `engine_in_valid=1` and `engine_in_ready=0`, the controller shall keep all of
the following unchanged:

```text
pending_sample_q
pending_valid_q
the complete engine input window
history_q
```

No input transfer, history update, or result-count change occurs during the
stall.  Consecutive accepted inputs are permitted; a future implementation may
use a queue or pipeline of pending windows, provided each accepted window uses
the history state before that transfer and each history update is atomic with
its own transfer.

### 7.5 Output and result commit independence

Engine output transfer and result-memory commit are separate events.  History
has already advanced at input acceptance and shall not be rolled back because a
later output or commit fails.  The controller shall:

1. Observe output transfers using `engine_out_valid && engine_out_ready`.
2. Attempt the corresponding result-memory write using the output transaction.
3. Increment `RESULT_COUNT` only after that write commits successfully.
4. Set `DONE` only after the final sample's result has committed successfully.

An output transfer followed by a failed result commit contributes to the
run-level output-transfer span in §8 but does not increment `RESULT_COUNT` and
cannot make the block valid.

### 7.6 Pending sample on reset

If hardware reset or `CTRL.RESET` occurs while a sample/window is pending, the
pending sample and unaccepted window are discarded.  History is cleared, no
history update occurs, no engine input or result commit is attributed to that
sample, and `RESULT_COUNT` is reset to zero.  Result BRAM is not physically
cleared.

### 7.7 Pending sample on internal error

If an internal error occurs while a sample is pending and before its engine input
transfer, the pending sample and unaccepted window are discarded and history
does not advance for that sample.  Earlier accepted inputs and successful
commits remain reflected in the partial diagnostics:

```text
RESULT_COUNT = number of earlier successful result-memory commits
STATUS.ERROR = 1
DONE         = 0
complete block = invalid
```

The absence of an engine transfer for the faulting sample does not mean that no
engine transfer occurred in the run.  `COMPUTE_CYCLES` follows the complete
run-level rule in §8.3.

## 8. Cycle-accounting contract

Cycle values are defined by transfer/completion edges, not by a particular FSM
state count or by a nominal engine `cycles` field.

### 8.1 Run events

The controller shall make the following conceptual edges observable in waveform
or trace evidence:

| Event | Definition |
|---|---|
| `e_start` | Rising edge on which a valid START is accepted and ownership is reserved. |
| `e_sample[n]` | Rising edge on which the synchronous sample response for sample `n` is captured into the pending register. |
| `e_in[n]` | Rising edge on which `engine_in_valid && engine_in_ready` accepts window `n`. |
| `e_out[n]` | Rising edge on which `engine_out_valid && engine_out_ready` transfers output `n`. |
| `e_commit[n]` | Rising edge on which output `n` is successfully written to result memory. |
| `e_done` | Rising edge of the final successful result-memory commit. |
| `e_error` | Rising edge on which an internal BRAM or engine fault terminates the run. |

Host/debug transaction errors do not create `e_error` and do not change the
active run's transfer trace.

### 8.2 CYCLES_TOTAL

For a successful block:

```text
CYCLES_TOTAL = e_done - e_start
```

For an internal-fault termination:

```text
CYCLES_TOTAL = e_error - e_start
```

The interval includes validation/setup, synchronous memory activity, pending
window formation, engine transfers, pipeline drain, and result commits.  A
preflight-invalid START has no run and therefore leaves `CYCLES_TOTAL=0`.

### 8.3 COMPUTE_CYCLES

On any run for which at least one engine output transfer has occurred:

```text
COMPUTE_CYCLES = last observed e_out - first observed e_in
```

On a successful run, `last observed e_out` is the final output-transfer edge.  On
an internal error, the same expression uses the last output transfer observed
anywhere in the run, even if the faulting sample had not yet been accepted or
even if a later result commit failed.

`COMPUTE_CYCLES=0` only when no engine output transfer has occurred during the
entire run.  In particular, a run with five committed outputs that faults while
preparing sample six retains the partial span from the first accepted engine
input to the fifth output transfer; it does not reset the value to zero merely
because sample six had no engine transfer.

`COMPUTE_CYCLES` and `CYCLES_TOTAL` from an error-terminated run are diagnostic
partial measurements only.  They do not make a partial result block valid.

### 8.4 Result count and derived metrics

`RESULT_COUNT` is incremented only on `e_commit[n]` after a successful
result-memory write.  It is not incremented on `e_sample`, `e_in`, `e_out`, or a
failed commit.  A trace may additionally derive setup cycles, per-sample input
to output latency, inter-sample gap, initiation interval, fill, and drain, but
those derived values are not initial V1.0 CSRs.

## 9. Pipeline-latency resolution experiment

The current RTL uses a `LATENCY = TREE_LEVELS + 1` convention, while the V2.2
reference pipeline rule describes `L_PIPE = TREE_LEVELS + 2` for registered
products, one registered stage per reduction level, and a registered final
extraction/output stage.  This contract does not claim that the discrepancy has
been measured or settled.

Before implementation claims or PPA interpretation depend on the value, execute
a direct `fir_pipelined_engine` waveform experiment for `LANES=4, 8, 16, 32`.
The experiment shall:

1. Timestamp the input-accepting edge and the first corresponding output
   transfer edge with `out_ready=1`.
2. Record the observed edge-to-edge latency separately from the engine's
   reported `cycles` field.
3. Exercise reset before traffic, pipeline fill, sustained back-to-back input,
   output drain, and output backpressure.
4. Assert output ordering, data stability while stalled, and one output per
   accepted input after reset flush.
5. Record the lane count, source revision, simulator/tool version, stimulus,
   clock-edge convention, and resulting latency in machine-readable metadata.

The no-stall transfer-edge result resolves the baseline latency convention;
backpressure results are retained separately because stalled elapsed latency is
not the same metric as nominal pipeline depth.  Until this experiment is run,
pipeline latency is **UNVERIFIED**.

## 10. Fair PPA and performance characterization contract

Characterization shall distinguish architecture area from selector/system area.
The target part is `xc7a35tcpg236-1` (Digilent Basys 3 / Artix-7
`XC7A35T-1CPG236C`) with the common 100 MHz OOC clock constraint used by the
repository flow.

### 10.1 Required comparison sets

| Set | Physical build | Runtime/workload rule | Reporting use |
|---|---|---|---|
| Sequential standalone | One unparameterized iterative engine and one multiplier | Matched tap counts and blocks; runtime tap count does not change the physical multiplier count | Sequential architecture baseline |
| Parallel standalone | `LANES=4,8,16,32` | Fixed physical lane build; inactive lanes are zero-gated for smaller runtime tap counts | Parallel area/latency/throughput |
| Pipelined standalone | `LANES=4,8,16,32` | Same fixed-physical rule as Parallel, with transfer-edge latency measured separately | Pipelined area/latency/throughput |
| Selector/adaptive integration | All candidate engines plus selector/frontend | Report as a system composition only | Never substitute for a standalone architecture result |

For matched active-tap comparisons, use the same input blocks, coefficients,
history initialization, numerical contract, clock constraint, reset/IO policy,
and acceptance criteria.  For fixed-physical-runtime studies, retain the
physical `LANES` or engine configuration in every result label; runtime tap
gating must not be presented as removal of synthesized hardware.

### 10.2 Required evidence and fairness rules

Use the same pinned Vivado/tool version, target part, synthesis mode, clock
constraint, top-level reset convention, and report extraction procedure.  Record
LUT, FF, DSP, BRAM, timing slack/Fmax, measured transfer latency, throughput,
and power only when the corresponding evidence exists.  Do not report OOC
standalone results as complete SoC area, final post-route timing, board power,
or hardware validation.

The selector/adaptive build contains all candidate engines and selection logic;
its resource footprint is not a valid standalone Sequential, Parallel, or
Pipelined PPA result.  The controlled three-way comparison remains separate
from future AutoArch policy experiments.

## 11. Current implementation deviation table

The following table was rechecked against commit
`74f4f66eef483ea99569177e5781d8a91067862a` and the named repository evidence.
`TEST-PROVEN` means that a named testbench and command directly exercise the
row. `INSPECTION-ONLY` means that the current RTL/docs support the statement,
but the cited tests do not directly prove the complete row. `OPEN` and
`UNVERIFIED` remain available for incomplete behavior or missing evidence;
these labels are not blanket verification claims.

| Area | Status | Current evidence and contract impact |
|---|---|---|
| Protected memory reads while owned | **TEST-PROVEN** | `tests/rtl/tb_nexus32_soc_protected_access.sv` directly drives PicoRV32 firmware through an owned sample read and checks `0xBAD0_0001`, the ownership event, the CPU-side fault, and preservation of the active result. The bus-level `tb_nexus32_accel_bus.sv` also checks the owned-read sentinel. Command: `bash scripts/run_rtl_smoke.sh`. Current RTL ownership/sentinel paths are in `rtl/nexus32_accel_bus.sv:187-223`. |
| Ownership violations affecting the active result | **TEST-PROVEN** | `tests/rtl/tb_nexus32_soc_protected_access.sv` checks the CPU-driven protected result write while the accelerator owns the banks, then requires a successful result commit, unchanged result memory, and no accelerator `ERROR`. The direct `tests/rtl/tb_fir_seq_accel.sv` coverage also checks owned-write rejection without suppressing the active run. Command: `bash scripts/run_rtl_smoke.sh`. |
| CPU bridge preserves errored read data | **TEST-PROVEN** | `tests/rtl/tb_nexus32_soc_protected_access.sv` checks that firmware reads `0xBAD0_0001` through the CPU bridge, while `tests/rtl/tb_nexus32_soc_fault_data.sv` directly checks `cpu_mem_rdata`, `accel_rsp_error`, sticky fault setting, and reset clearing. Commands: `bash scripts/run_rtl_smoke.sh` and `make test-fault`. Current bridge response preservation is in `rtl/nexus32_soc.sv:96-105,174-188`. |
| Debug registers and event classes | **TEST-PROVEN** | `tests/rtl/tb_fir_seq_accel.sv` exercises `MEM_OWNERSHIP`, `CONFIG_WHILE_BUSY`, `BRAM_FAULT`, `BUS_UNMAPPED`, `ENGINE_ERROR`, metadata priority/ties, W1C, and RESET behavior; `tests/rtl/tb_nexus32_accel_bus.sv` exercises `INVALID_CONFIG`, `RESULT_WRITE_FORBIDDEN`, `BUS_ACCESS`, reserved accesses, and sticky-fault separation. Command: `bash scripts/run_rtl_smoke.sh`. The eight event classes and CSR offsets are defined in `rtl/fir_seq_accel.sv:90-120`, with status/metadata reads at `:966-975`. |
| `SAMPLE_COUNT` meaning | **TEST-PROVEN** | `tests/rtl/tb_fir_seq_accel_block_1024.sv` and `tests/rtl/tb_fir_seq_accel_block_processing.sv` configure block length, count all input/output/commit events, compare `RESULT_COUNT` with the configured sample count, and distinguish it from `SAMPLE_COUNT`. Command: `bash scripts/run_verification_closure.sh`. Current register behavior is in `rtl/fir_seq_accel.sv:18-20,943-965`. |
| Block processing and history | **TEST-PROVEN** | `tests/rtl/tb_fir_seq_accel_block_processing.sv` exercises the multi-result iterator, zero-history block starts, rolling history, pending-sample stalls, snapshot stability, reset flushing, and ordered physical commits across all three architectures and supported lane builds. Command: `bash scripts/run_verification_closure.sh`. |
| Timing-counter definitions | **TEST-PROVEN** | `tests/rtl/tb_fir_seq_accel_block_1024.sv` and `tests/rtl/tb_fir_seq_accel_block_processing.sv` derive `CYCLES_TOTAL` from START-to-final-commit or START-to-error edges and `COMPUTE_CYCLES` from first input transfer to last output transfer, including partial-fault cases. Command: `bash scripts/run_verification_closure.sh`. |
| START while BUSY | **TEST-PROVEN** | `tests/rtl/tb_fir_seq_accel_block_config.sv` and `tests/rtl/tb_fir_seq_accel_config_stage.sv` issue START while busy and check `rsp_error=0`, preserved BUSY/ownership, unchanged debug state, and normal continuation; other configuration writes remain rejected. Command: `bash scripts/run_verification_closure.sh`. Current decode is in `rtl/fir_seq_accel.sv:397-424`. |
| Preflight versus internal fault separation | **TEST-PROVEN** | `tests/rtl/tb_fir_seq_accel_block_config.sv` and `tests/rtl/tb_fir_seq_accel_block_processing.sv` check well-formed invalid START completion with `rsp_error=0`, no ownership or memory access, `INVALID_CONFIG`, and zero counters; the same suites inject BRAM/commit faults and check ERROR termination, partial validity, and RESET-only recovery. Command: `bash scripts/run_verification_closure.sh`. |
| Reserved `AUTO_*`, version, and build registers | **INSPECTION-ONLY** | Current RTL defines `AUTO_CFG`, `AUTO_SELECTED`, `AUTO_MODEL_ID`, `CONTRACT_VERSION`, and `BUILD_ID`, returns zero on reads, and routes unsupported writes to the error path (`rtl/fir_seq_accel.sv:90-105,950-975`). `tests/rtl/tb_nexus32_accel_bus.sv` directly checks `AUTO_CFG` and an unlisted CSR, but does not directly exercise every reserved offset, so the complete row is not test-proven. Command for the partial coverage: `bash scripts/run_rtl_smoke.sh`. |
| Pipeline latency | **TEST-PROVEN** | `tests/rtl/tb_fir_pipelined_latency.sv` measures the direct engine at LANES 4, 8, 16, and 32, including fill, steady state, drain, output backpressure, output stability, and input-edge to output-transfer-edge latency. Command: `bash scripts/run_verification_closure.sh`. The measured transfer-edge convention is documented in `docs/VERIFICATION_CLOSURE.md:127-148`. |
| Vivado characterization | **UNVERIFIED** | The repository provides an OOC flow, but no Vivado run receipt is present. The flow explicitly excludes CPU, bus, BRAM gather, and arbitration (`vivado/README.md:79-118`). `docs/STATUS.md:49` records that no real Vivado synthesis, implementation timing, utilization, DRC, or bitstream generation has been run. |
| Physical hardware validation | **UNVERIFIED** | No bitstream programming, physical Basys 3 observation, or board measurement is recorded. `docs/STATUS.md:49` and `docs/PICORV32_PIN.md:22` retain the boundary that FPGA implementation and physical behavior remain unverified. |

The current implementation evidence is therefore mixed: rows marked
`TEST-PROVEN` have a named direct simulation command, `INSPECTION-ONLY` rows
are supported by current RTL or partial coverage without complete direct proof,
and the Vivado/physical rows remain `UNVERIFIED`. This contract does not
convert inspection or simulation into Vivado, timing, bitstream, or board
evidence; implementation and characterization claims still require fresh,
reproducible receipts.

## 12. Milestone 0 acceptance checklist

Milestone 0 is complete only when the contract is reviewed, traceable, and
approved.  The following checklist is the gate for subsequent implementation.

### 12.1 Authority and traceability

- [ ] Contract V1.0 is stored at `docs/ACCELERATOR_CONTRACT_V1.md`.
- [ ] The external V2.2 source is identified by title, version, date, and
      revision basis without inventing a specification commit SHA.
- [ ] Any V2.2 ambiguity or approved V1.0 addition is recorded rather than
      silently inferred from current RTL.
- [ ] The project leader has approved the contract and the next implementation
      batch separately.

### 12.2 Numerical and engine behavior

- [ ] Signed Q16.16 inputs and coefficients are used consistently.
- [ ] Products are signed 32×32→64 and explicitly sign-extended 64→72 before
      every accumulator/reduction-tree addition.
- [ ] No intermediate rounding or saturation occurs.
- [ ] Final arithmetic `>>>16` and signed 32-bit saturation are identical across
      all engines.
- [ ] Input/output valid-ready transfer events, ordering, and output stability
      under backpressure are covered by directed tests.

### 12.3 Memory protection and response semantics

- [ ] Coefficient, sample, and result regions are protected on the accepted
      START edge and throughout ownership.
- [ ] Owned reads return `0xBAD0_0001`, assert the host transaction error, and
      set `MEM_OWNERSHIP` without a BRAM side effect.
- [ ] Owned coefficient/sample writes return zero data, assert the host error,
      set `MEM_OWNERSHIP`, and do not affect the active run.
- [ ] Result writes are forbidden in every state, return zero data, set only
      `RESULT_WRITE_FORBIDDEN`, and never become `MEM_OWNERSHIP`.
- [ ] Unmapped transactions use `BUS_UNMAPPED` and `0xDEAD_BEEF`; mapped
      malformed/reserved accesses use `BUS_ACCESS`; decoded result writes take
      the `RESULT_WRITE_FORBIDDEN` priority; all have no mapped side effect.
- [ ] `DBG_STATUS` bits 0–5 clear only through idle W1C, bits 6–7 require RESET,
      and no debug W1C clears `STATUS.ERROR` for a RESET-only fault.
- [ ] Debug events, last-address/info registers, fixed same-edge priority and
      same-class tie rule, preservation of all simultaneous sticky bits, and
      W1C-while-BUSY rejection are tested.
- [ ] A well-formed preflight-invalid START completes with `rsp_error=0` and
      zero write-response data while setting `STATUS.ERROR`/`INVALID_CONFIG`;
      malformed START writes remain `BUS_ACCESS`.
- [ ] `cpu_bus_fault_o` is set only by errored host transactions and clears only
      on external hardware reset, not through accelerator/debug CSRs.
- [ ] The CPU bridge preserves errored read data and keeps the external sticky
      bus-fault diagnostic distinct from `STATUS.ERROR`.

### 12.4 Error and recovery behavior

- [ ] Preflight invalid configuration acquires no ownership and performs no
      accelerator memory access.
- [ ] Invalid configuration sets `ERROR`/`INVALID_CONFIG`, zeros run counters
      and `RESULT_COUNT`, and is recoverable after correction and W1C.
- [ ] Internal BRAM and engine faults terminate the run and require RESET;
      W1C cannot disguise them as recoverable errors.
- [ ] Host transaction failures do not set `STATUS.ERROR`, abort an active run,
      or change run counters.
- [ ] RESET wins over START, clears controller/debug state and counters, releases
      ownership, and leaves physical result BRAM uncleared.
- [ ] START while BUSY is a normal no-op, and START is rejected while ERROR
      remains set.

### 12.5 CSR and validity compatibility

- [ ] All V1.0 offsets, reset values, access types, reserved-register responses,
      and status W1C semantics are implemented exactly.
- [ ] `SAMPLE_COUNT` is configured block length, not a commit counter.
- [ ] `RESULT_COUNT` increments only after successful result-memory commits.
- [ ] Firmware success uses
      `BUSY==0 && DONE==1 && ERROR==0 && RESULT_COUNT==SAMPLE_COUNT`.
- [ ] Partial, stale, error-run, invalid-START, and reset-era result contents
      remain physically representable but fail the validity predicate.

### 12.6 Block/history behavior

- [ ] A synchronous sample response is captured into a pending-sample register.
- [ ] For `TAP_COUNT=1`, the window is exactly `[current_sample]` and contains
      zero history entries.
- [ ] The pending sample and pre-transfer history form a stable window.
- [ ] History advances atomically on `engine_in_valid && engine_in_ready`.
- [ ] Stalled input holds the pending sample, complete window, and history.
- [ ] Consecutive accepted inputs use the correct old/new history ordering.
- [ ] Output transfer and result commit are independent of history advancement.
- [ ] A pending sample is discarded on reset or internal error before acceptance;
      history does not advance for it.
- [ ] A run with five prior commits that faults while preparing sample six keeps
      `RESULT_COUNT=5` and retains the earlier run-level compute span.
- [ ] `COMPUTE_CYCLES=0` is asserted only when no output transfer occurred in
      the entire run.

### 12.7 Timing and characterization

- [ ] `CYCLES_TOTAL` uses START-to-final-commit or START-to-error edges.
- [ ] `COMPUTE_CYCLES` uses first input-transfer to last output-transfer edges,
      including the approved partial-span behavior on error.
- [ ] The direct pipelined latency experiment is executed for lanes 4, 8, 16,
      and 32 with fill, steady state, drain, reset, and backpressure evidence.
- [ ] Pipeline latency metadata records measured transfer-edge results and does
      not claim the `TREE_LEVELS+1`/`TREE_LEVELS+2` discrepancy is settled early.
- [ ] PPA results separate standalone architectures from selector/adaptive
      system area and use the common target, tools, constraints, and workloads.
- [ ] No OOC result is described as complete SoC, post-route, power, or board
      validation without corresponding evidence.

### 12.8 Regression and reproducibility

- [ ] The repository runtime/tool versions and dependency lock state remain
      reproducible; no private credentials are stored.
- [ ] Existing numerical, engine, bus, SoC, and selector regressions are run
      after implementation changes using the repository's actual scripts.
- [ ] Directed negative tests cover protection, malformed access, debug W1C,
      reset recovery, partial result validity, and pending-sample faults.
- [ ] Every characterization claim has a traceable command, source revision,
      tool version, configuration, and retained output artifact.
- [ ] Documentation-only Batch 1 does not claim simulation or hardware
      validation merely because the contract has been written.

## 13. Scope gate and next approval

This Batch 1 artifact establishes the contract only.  It intentionally does not
implement the RTL safety corrections, CPU bridge change, debug CSR path,
firmware migration, block iterator/history engine, AutoArch, DMA, HLS, hardware
bring-up, or later research work.

The next batch requires a separate project-leader approval after review of the
actual documentation diff.  Any implementation that conflicts with this
contract must stop and return to the project leader with an explicit change
record; it must not silently revise V1.0 during coding.
