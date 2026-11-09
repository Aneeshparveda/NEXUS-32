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

The zip holds the repository plus the two inputs Windows cannot build
(`vendor/picorv32/*`, `firmware/nexus32_smoke.hex`) and `BUNDLE_COMMIT.txt`
(commit, dirty flag, input hashes). Copy it over by USB or cloud drive.
A plain `git clone` on Windows is **not** enough: those inputs are gitignored.

## 1. Windows setup

1. Unzip to a short path **without spaces**, e.g. `C:\nexus32`
   (long or spaced paths are a common Vivado failure).
2. Note the Vivado version (`vivado -version`, or Help > About). The flows
   were written against 2024.2; record whatever version is used.
3. No bash, Python, RISC-V toolchain, git or network is needed. On Windows
   `build_basys3.tcl` defaults to `NEXUS32_INPUTS=prebuilt` and verifies the
   bundle (pinned PicoRV32 revision and SHA-256, 4096-word firmware image)
   before synthesis.

## 2. Run order

Double-click each `.bat` from `C:\nexus32\vivado\`, or run it from `cmd`.

| Step | Command | What it gives | Rough time |
|---|---|---|---|
| 1 | `RUN_VIVADO_CORES.bat` | Out-of-context synthesis of each engine alone at LANES 4/8/16/32: LUT, FF, **DSP**, BRAM, WNS per engine | longest step |
| 2 | `RUN_VIVADO_BASYS3.bat 4` | Full SoC, synth through bitstream, smallest build | 10–30 min |
| 3 | `RUN_VIVADO_BASYS3.bat 8` | Board default build | 10–30 min |
| 4 | `RUN_VIVADO_BASYS3.bat 16` | Only if step 3 leaves DSP headroom | 10–30 min |

Outputs: `results\vivado_core\characterization_summary.md` (step 1) and
`results\vivado\basys3_l<LANES>\` (steps 2–4).

## 3. Check each board build

Open `results\vivado\basys3_l<LANES>\build_summary.md` first.

| Check | Where | Pass condition |
|---|---|---|
| Flow status | `build_summary.md` | `Build status: PASS` |
| Firmware loaded | `vivado.log`, line `IMEM init check:` | `N of M IMEM block RAMs carry firmware data`, N > 0 |
| DSP fit | `reports\post_implementation\utilization.rpt`, DSPs | ≤ 90 (XC7A35T has 90 DSP48E1) |
| Block RAM | same report, Block RAM Tile | expected roughly 11 of 50 (IMEM 4, DMEM 4, result/sample/coeff 1 each); a much lower count with high LUTRAM means a memory did not infer as BRAM |
| Timing | `reports\post_implementation\timing_summary.rpt` | WNS ≥ 0 ns at 10.000 ns |

## 4. If something fails

| Symptom | Likely cause | Action |
|---|---|---|
| `Vivado was not found` | Not on PATH and not under `C:\Xilinx` or `C:\AMDDesignTools` | Open a cmd window and call `<Vivado install>\bin\vivado.bat -mode batch -source vivado/build_basys3.tcl -tclargs results/vivado/basys3_l8 8` from `C:\nexus32` |
| `vendor_rtl FAIL` | Bundle missing or altered `vendor/` or firmware | Rebuild the bundle on the dev machine; do not hand-edit |
| Synthesis error mentioning `IMEM_INIT_FILE` | Vivado rejected the quoted string generic | In cmd: `set NEXUS32_IMEM_GENERIC=0`, then rerun the `.bat` |
| `post_synth.imem_init_check FAIL` | Firmware image not loaded into IMEM | Do **not** program the board; bring back `vivado.log` |
| Placement fails, DSP or LUT over-utilized | LANES too large for the part | Use the next smaller LANES |
| WNS negative | Single-cycle 32×32 multiplies in the parallel/pipelined engines are the expected critical paths | Bitstream still builds but is **not** valid at 100 MHz; keep reports, record WNS and the critical path, do not claim board timing |

## 5. Program the board (only if the Basys 3 is present)

Only with `Build status: PASS`, IMEM check passed, and WNS ≥ 0:

1. Connect the Basys 3 rev-B by USB, power on.
2. Vivado > Open Hardware Manager > Open Target > Auto Connect.
3. Program Device with `results\vivado\basys3_l<LANES>\top_basys3.bit`.
4. Press and release the centre button (reset).
5. Expected: `LD0` on (boot), `LD2` on (PASS), `LD3` off (no trap/fault).
   `LD1` (busy) is too short to see.
6. Record board revision, LANES, bitstream SHA-256 (from `build_summary.md`),
   observed LEDs, date. Take a photo.

## 6. Bring the evidence back

In PowerShell from `C:\nexus32`:

```powershell
Compress-Archive -Path results\vivado, results\vivado_core -DestinationPath nexus32-vivado-results.zip
```

Unzip it into the repository's `results/` folder on the dev machine. Nothing
under `results/` is committed; summarize the numbers into `docs/STATUS.md`
and the README Results section with the commit, Vivado version and LANES
attached to every figure.
