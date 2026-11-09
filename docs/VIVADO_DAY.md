# Vivado day runbook (Windows host)

First real Vivado and board run of NEXUS-32. The goal is evidence:
utilization, timing, and a board that reports its own results over UART.
Nothing in this file is a result; it is the procedure. The tools record what
actually happens.

## Short version

On the dev machine: `make test-all`, commit, `bash scripts/make_vivado_bundle.sh`.
On the Windows laptop, from `C:\nexus32\vivado\`, double-click in order:

| Step | Double-click | Board needed | Time | Produces |
|---:|---|:---:|---|---|
| 1 | `RUN_ALL.bat` | no | 1–2 h, unattended | every build, the 50 MHz retry if needed, the core sweep, `nexus32-evidence.zip` |
| 2 | `PROGRAM_BOARD.bat` | yes | 1 min | best build programmed; LD0 + LD2 on, LD3 off |
| 3 | `READ_UART.bat` | yes | 15 s | `results\evidence\uart_log.txt` with the board's own report |
| 4 | `COLLECT_EVIDENCE.bat` | no | 1 min | refreshed `EVIDENCE.md` and `C:\nexus32\nexus32-evidence.zip` |

Send back `C:\nexus32\nexus32-evidence.zip` and a phone photo of the board.

## 0. Before leaving the dev machine (macOS/Linux, toolchain installed)

```bash
make setup                                # once: pinned PicoRV32 + firmware
make test-all                             # must pass before handing off
git commit ...                            # so the bundle is not "-dirty"
bash scripts/make_vivado_bundle.sh        # -> results/handoff/nexus32-vivado-<sha>.zip
```

The zip holds the repository plus what Windows cannot build: the pinned
PicoRV32 source, both firmware images (`nexus32_demo.hex`, `nexus32_smoke.hex`)
and `BUNDLE_COMMIT.txt` (commit, dirty flag, input hashes). A plain
`git clone` on Windows is **not** enough: those inputs are gitignored.

## 1. Windows setup (once)

1. If the zip came from a browser or cloud drive: right-click it >
   Properties > tick **Unblock** > OK. Otherwise Windows may block the `.bat`
   files ("Windows protected your PC": More info > Run anyway).
2. Extract it. The zip contains one folder, `nexus32`. Move that folder so the
   repository is exactly `C:\nexus32` (so `C:\nexus32\vivado\RUN_ALL.bat`
   exists). Short path, **no spaces**.
3. Nothing else is needed: no bash, Python, RISC-V toolchain, git or network.
   Vivado is found on PATH, under `C:\Xilinx\Vivado\<ver>` or under
   `C:\AMDDesignTools\<ver>`.

## 2. RUN_ALL.bat (no board needed)

Runs these steps, continues past a failed step, and logs each step's exit code
to `results\run_all_log.txt`:

1. `RUN_VIVADO_BASYS3.bat 4 100`: full SoC, LANES=4, 100 MHz, synthesis to
   bitstream. Fastest path to a first bitstream.
2. `RUN_VIVADO_BASYS3.bat 8 100`: board default.
3. `RUN_VIVADO_BASYS3.bat 8 50`: **only if** step 2 did not meet timing
   (`TIMING_MET=NO` in its `metrics.txt`). Uses the MMCM to clock the SoC at
   50 MHz, so timing is checked at 20 ns.
4. `RUN_VIVADO_CORES.bat`: out-of-context synthesis of each engine alone at
   LANES 4/8/16/32 and the selector (LUT, FF, DSP, BRAM, WNS). The longest step.
5. `COLLECT_EVIDENCE.bat`: `results\evidence\EVIDENCE.md` and the zip.

Each board build writes `results\vivado\<build>\`:
`build_summary.md` (stages, key metrics), `metrics.txt` (machine-readable),
`vivado.log`, `reports\post_synth\*` and `reports\post_implementation\*`
(utilization, timing, DRC, checkpoints) and `top_basys3.bit`.

Expect 100 MHz timing to be tight or negative: every engine does a 32x32
multiply, a 72-bit add and saturation in one cycle. That is what the 50 MHz
build is for. A build with negative WNS still produces a bitstream, but it is
not timing evidence.

## 3. PROGRAM_BOARD.bat (board needed)

USB cable in the Basys 3 PROG/UART port, power switch ON. The script picks the
first build in this order that passed the flow, passed the IMEM check and met
timing: `basys3_l8`, `basys3_l8_50mhz`, `basys3_l4`, ... If none met timing it
uses the first passing build and says so (functional check only). To force a
build: `PROGRAM_BOARD.bat basys3_l4`.

After programming: **LD0** on (firmware booted), **LD2** on (all three engines
matched the golden checksum), **LD3** off (no trap, bus fault or accelerator
error). LD1 (busy) is too short to see.

## 4. READ_UART.bat (board needed)

Reads the board's USB serial port (115200 8N1) for 15 s and saves
`results\evidence\uart_log.txt`. The COM port is auto-detected when only one
exists; otherwise it lists them and asks (the Basys 3 one is "USB Serial Port
(COMx)" in Device Manager > Ports). The firmware re-prints its report about
every 1.6 s, for example:

```text
=== NEXUS-32 board demo (PicoRV32 + 3 FIR engines) ===
build: LANES=8 CLK_MHZ=100 TAP_COUNT=8 SAMPLE_COUNT=1024 golden_checksum=0xb2be7f16
arch=SEQ     check=PASS cycles_total=14352 compute_cycles=14332 result_count=1024 checksum=0xb2be7f16 status=0x00000002
arch=PAR     check=PASS cycles_total=5136 compute_cycles=5116 result_count=1024 checksum=0xb2be7f16 status=0x00000002
arch=PIPE    check=PASS cycles_total=9232 compute_cycles=9212 result_count=1024 checksum=0xb2be7f16 status=0x00000002
NEXUS32 RESULT: PASS
```

(That block is the LANES=8 **simulation** output; the board's own numbers are
the evidence. Cycle counts are clock-independent, so a 50 MHz build prints
the same counts.) Any terminal works too: Tera Term or PuTTY, Serial, the COM
port, 115200, 8 data bits, no parity, 1 stop bit.

## 5. COLLECT_EVIDENCE.bat

Rebuilds `results\evidence\EVIDENCE.md` with everything found (board builds,
core sweep, programmed build, UART verdict and last report, run log,
provenance) and zips `results\evidence` to `C:\nexus32\nexus32-evidence.zip`.
Bitstreams, checkpoints and netlists are left out; every number is copied
from a tool-written file.

## 6. Screenshots and photos worth taking

- Board photo: LD0 and LD2 on, LD3 off, with the date visible (phone is fine).
- The `READ_UART.bat` window showing `NEXUS32 RESULT: PASS`.
- Optional, for the README/paper: `OPEN_IN_VIVADO_GUI.bat basys3_l8` opens the
  routed design; Window > Device shows the floorplan, Reports > Report
  Utilization / Report Timing Summary show the tables.

## 7. If something fails

Open `results\vivado\<build>\build_summary.md` first: it names the failing stage.

| Symptom | Likely cause | Action |
|---|---|---|
| `Vivado was not found` | Not on PATH and not under `C:\Xilinx` or `C:\AMDDesignTools` | Add Vivado's `bin` to PATH, or open the Vivado Tcl Shell and run `RUN_ALL.bat` from it |
| `vendor_rtl FAIL` | Bundle missing or altered `vendor/` or firmware | Rebuild the bundle on the dev machine; do not hand-edit |
| Synthesis error mentioning `IMEM_INIT_FILE` | Vivado rejected the quoted string generic | In cmd: `set NEXUS32_IMEM_GENERIC=0`, then run the `.bat` from that window |
| `post_synth.imem_init_check FAIL` | Firmware not loaded into IMEM | Do **not** program; send `vivado.log`. Override (`set NEXUS32_SKIP_IMEM_CHECK=1`) only if `utilization_hierarchical.rpt` shows IMEM in LUTs |
| Placement fails, DSP or LUT over-utilized | LANES too large | Use a smaller LANES |
| WNS negative at 50 MHz too | Long combinational paths | `RUN_VIVADO_BASYS3.bat 8 25`; send the reports either way |
| Synthesis error in `MMCME2_BASE` (50/25 MHz only) | MMCM settings rejected by this Vivado release | Send `vivado.log`; use the 100 MHz build for the LED/UART check |
| `PROGRAM_BOARD.bat`: no board found | Cable, power switch, or cable driver | Use the PROG/UART micro-USB port, switch ON, install the Digilent/FTDI driver (Vivado installer option) |
| `READ_UART.bat`: no RESULT line | Wrong COM port or board not programmed | Rerun with the port named, e.g. `READ_UART.bat COM5`; press the centre button during the capture |
| A `.bat` window flashes and closes | Error before the pause | Run it from `cmd` to read the message |

Run a single step by hand from `C:\nexus32\vivado\` (each pauses at the end):
`RUN_VIVADO_BASYS3.bat <LANES> <MHZ>`, `RUN_VIVADO_CORES.bat`,
`PROGRAM_BOARD.bat [build]`, `READ_UART.bat [COMx]`, `COLLECT_EVIDENCE.bat`.
Set `NEXUS32_FIRMWARE=smoke` in cmd first for the original LED-only firmware.
