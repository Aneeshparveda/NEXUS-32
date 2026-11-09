# Vivado day runbook (Windows host)

First real Vivado run of NEXUS-32. The goal is evidence: utilization, timing
and, if the board is available, a programmed bitstream. Nothing in this file
is a result; it is the procedure. Record what actually happens.

## 0. Before leaving the dev machine (macOS/Linux, toolchain installed)

```bash
make setup                                # once: pinned PicoRV32 + firmware
make test-all                             # must pass before handing off
bash scripts/make_vivado_bundle.sh        # -> results/handoff/nexus32-vivado-<sha>.zip
```

Commit first, so the zip name has no `-dirty` suffix. The zip holds the
repository plus the two inputs Windows cannot build (`vendor/picorv32/*`,
`firmware/nexus32_smoke.hex`) and `BUNDLE_COMMIT.txt` (commit, dirty flag,
input hashes). Copy it over by USB or cloud drive. A plain `git clone` on
Windows is **not** enough: those inputs are gitignored.

## 1. Windows setup

1. If the zip came from a browser or cloud drive: right-click it >
   Properties > tick **Unblock** > OK. Otherwise Windows may block the
   `.bat` files ("Windows protected your PC": More info > Run anyway).
2. Extract it. The zip contains one folder, `nexus32`. Move that folder so
   the repository is exactly `C:\nexus32` (so `C:\nexus32\vivado\` exists).
   Short path, **no spaces**: long or spaced paths are a common Vivado failure.
3. Note the Vivado version (Help > About, or `vivado -version`). The flows
   were written against 2024.2; record whatever version is used.
4. Nothing else is needed: no bash, Python, RISC-V toolchain, git or network.
   On Windows `build_basys3.tcl` uses `NEXUS32_INPUTS=prebuilt` and verifies
   the bundle (pinned PicoRV32 revision and SHA-256, 4096-word firmware) before
   synthesis.

## 2. Run order (fastest path to a first bitstream first)

Open `cmd`, `cd C:\nexus32\vivado`, and run each line. Double-clicking the
`.bat` also works for the default arguments.

| Step | Command | What it gives | Rough time |
|---|---|---|---|
| 1 | `RUN_VIVADO_BASYS3.bat 4` | Full SoC at 100 MHz, synth through bitstream, smallest build: **first output** | 10–30 min |
| 2 | `RUN_VIVADO_BASYS3.bat 8` | Board default build | 10–30 min |
| 3 | `RUN_VIVADO_BASYS3.bat 8 50` | Only if step 2 misses timing (WNS < 0): same build at 50 MHz via the MMCM | 10–30 min |
| 4 | `RUN_VIVADO_CORES.bat` | Out-of-context synthesis of each engine alone at LANES 4/8/16/32 (LUT, FF, **DSP**, BRAM, WNS); can run while you program the board | longest step |
| 5 | `RUN_VIVADO_BASYS3.bat 16` | Only if step 2 leaves DSP headroom | 10–30 min |

Outputs: `results\vivado\basys3_l<LANES>\` (or `basys3_l<LANES>_<MHZ>mhz\`)
and `results\vivado_core\characterization_summary.md`.

Expect timing at 100 MHz to be tight or negative: every engine does a 32x32
multiply, a 72-bit add and saturation in one cycle. A negative WNS still
produces a bitstream; it is just not valid evidence at 100 MHz. That is what
step 3 is for.

## 3. Check each board build

Open `results\vivado\<build>\build_summary.md` first.

| Check | Where | Pass condition |
|---|---|---|
| Flow status | `build_summary.md` | `Build status: PASS` |
| Firmware loaded | `vivado.log`, line `IMEM init check:` | `N of M IMEM block RAMs carry firmware data`, N > 0 |
| DSP fit | `reports\post_implementation\utilization.rpt`, DSPs | ≤ 90 (XC7A35T has 90 DSP48E1) |
| Block RAM | same report, Block RAM Tile | roughly 11 of 50 (IMEM 4, DMEM 4, result/sample/coeff 1 each); far fewer with high LUTRAM means a memory did not map to BRAM |
| Timing | `reports\post_implementation\timing_summary.rpt` | WNS ≥ 0 ns |

## 4. If something fails

| Symptom | Likely cause | Action |
|---|---|---|
| `Vivado was not found` | Not on PATH and not under `C:\Xilinx` or `C:\AMDDesignTools` | From `C:\nexus32` run `"<Vivado install>\bin\vivado.bat" -mode batch -source vivado/build_basys3.tcl -tclargs results/vivado/basys3_l4 4` |
| `vendor_rtl FAIL` | Bundle missing or altered `vendor/` or firmware | Rebuild the bundle on the dev machine; do not hand-edit |
| Synthesis error mentioning `IMEM_INIT_FILE` | Vivado rejected the quoted string generic | In cmd: `set NEXUS32_IMEM_GENERIC=0`, then rerun the `.bat` from the same window |
| `post_synth.imem_init_check FAIL` | Firmware not loaded into IMEM | Do **not** program the board. Bring back `vivado.log`. Override (`set NEXUS32_SKIP_IMEM_CHECK=1`) only if `utilization_hierarchical.rpt` shows IMEM present in LUTs |
| Placement fails, DSP or LUT over-utilized | LANES too large for the part | Use the next smaller LANES |
| WNS negative | Single-cycle 32x32 multiply paths | Run the same LANES with `50` (then `25`) as the second argument |
| Synthesis error in `MMCME2_BASE` (50/25 MHz only) | MMCM settings rejected by this Vivado release | Bring back `vivado.log`; use the 100 MHz bitstream for the LED test meanwhile |
| A `.bat` window flashes and closes | Double-clicked with an error | Run it from `cmd` to read the message |

## 5. Program the board (only if the Basys 3 is present)

Use a build with `Build status: PASS` and the IMEM check passed. Prefer one
with WNS ≥ 0. The smoke firmware exercises the sequential engine through the
CPU, so the LED test is the first functional check, but only a WNS ≥ 0 build
counts as timing evidence.

1. Connect the Basys 3 rev-B by USB, power on.
2. Vivado > Open Hardware Manager > Open Target > Auto Connect.
3. Program Device with `results\vivado\<build>\top_basys3.bit`.
4. Press and release the centre button (reset).
5. Expected: `LD0` on (boot), `LD2` on (PASS), `LD3` off (no trap/fault).
   `LD1` (busy) is too short to see.
6. Record board revision, LANES, clock, bitstream SHA-256 (from
   `build_summary.md`), observed LEDs, date. Take a photo.

## 6. Bring the evidence back

In PowerShell from `C:\nexus32`:

```powershell
Compress-Archive -Path results\vivado, results\vivado_core -DestinationPath nexus32-vivado-results.zip
```

If `results\vivado_core` does not exist yet (step 4 not run), drop it from the
command. Unzip into the repository's `results/` folder on the dev machine.
Nothing under `results/` is committed; summarize the numbers into
`docs/STATUS.md` and the README Results section with the commit, Vivado
version, LANES and clock attached to every figure.
