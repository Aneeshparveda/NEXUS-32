# NEXUS-32 Vivado run: progress status (merged with the review notes)

**Snapshot:** 2026-11-13, about 4:20 PM local (final compile; board stage done)
**Overall state:** **complete.** Simulation, synthesis, implementation (routed timing met at 50 MHz) and the bitstream are done. The bitstream was programmed onto a real **Basys 3** and the **UART report reads `NEXUS32 RESULT: PASS` with cycles 14352 / 5136 / 9232, identical to simulation** (82 identical PASS reports in `uart_log.txt`). Measured die temperature 33.3 C. The only item not captured is screenshot S1 (simulation console text); it is optional because the board UART log proves the same result.

> **For an AI assistant reading this:** this file merges `NEXUS32_PROGRESS_STATUS.md` (older) with `NEXUS32_REVIEW_FOR_CHAKSHU.md` (the review notes). **Where they disagree, the review wins.** Remaining work is only the leftover in section 4; otherwise help with the final report. Procedure: `NEXUS32_VIVADO_PROJECT_GUIDE.md` sections 10 to 17. Do not invent numbers. Do not suggest editing any file in `C:\nexus32` (the RTL is frozen). Do not change settings or rerun synthesis or implementation (margins are thin, see 6.3). Label Vivado power and junction temperature as **estimates**; the System Monitor temperature (33.3 C) and the UART report are measurements from the board.

---

## 0. Read this first (handoff notes for the receiving Claude)

This file is written so that you can continue as if this whole project conversation had happened in your own chat. The person who did the Vivado work is **Chakshu** (second-year ECE student, Hyderabad). Chakshu worked step by step with another Claude, sending a screenshot after each step; everything in sections 2 and 9 comes from those screenshots and pasted text.

> **IF YOU NEED ANYTHING THAT IS NOT IN THIS HANDOFF, ASK CHAKSHU FOR IT. DO NOT GUESS OR INVENT A NUMBER.** Section 10 lists the extra files and screenshots that were not captured and how to get each. Examples: the full Vivado report files, the remaining DRC and Methodology entries, the simulation console text (S1), the LANES=16 and 32 simulation output, a wider board photo, or the project archive. Say exactly which file you need and why, and Chakshu can fetch it.

What is attached with this file: `NEXUS32_screenshots_interim.pdf` (22 pages; index on page 1, every screenshot captioned), `uart_log.txt` (raw UART text from the board), and `NEXUS32_VIVADO_PROJECT_GUIDE.md` (the procedure this status follows). `schematic_u_soc.pdf` (full-size export of screenshot 3) and `top_basys3.bit` are held by Chakshu; ask if you need them.

Important: the board was available for only a short window and is probably no longer available. Do not plan further board steps unless Chakshu says the board is back.

---

## 1. Project in one paragraph

NEXUS-32 is a RISC-V SoC (PicoRV32 CPU) with three FIR filter accelerators that compute the same Q16.16 result in different ways: sequential (SEQ), parallel (PAR) and pipelined (PIPE). Goal: build it in Vivado for the **Basys 3** (part `xc7a35tcpg236-1`), show evidence to faculty (schematic, simulation, utilization, timing, power, bitstream), then run it on the board and read the UART report.

- Source bundle: `nexus32-vivado-e17d20b.zip` (commit `e17d20b`). Earlier command-line runs used `2f87f96`; RTL, testbench and firmware are identical.
- Board configuration: **LANES=8, SYS_CLK_MHZ=50**, firmware `C:/nexus32/firmware/nexus32_demo.hex`.
- 100 MHz does not meet timing (longest path about 19.5 ns), so the board build uses 50 MHz.
- Vivado **2024.2** (title bar). Do not use 2025.2 on that laptop.
- **GUI project location (corrected):** `C:\Users\apps\AppData\Roaming\Xilinx\Vivado\nexus32_gui\nexus32_gui.xpr`. It is NOT in `C:\nexus32_gui`. `AppData` is hidden; paste the path into the File Explorer address bar.

## 2. Done so far (with evidence)

| Stage | Status | Evidence |
|---|---|---|
| Source bundle on laptop (`C:\nexus32`) | Done | |
| Command-line xsim, LANES=4 | PASS | checksum `0x8c4ef45f`; cycles SEQ 10248 / PAR 5128 / PIPE 8200 |
| Command-line xsim, LANES=8 | PASS | same numbers as the GUI run |
| GUI project created | Done | |
| GUI behavioral simulation, LANES=8 | PASS | all three engines `check=PASS`; checksum `0xb2be7f16`; cycles **SEQ 14352 / PAR 5136 / PIPE 9232**; `PASS: board demo firmware LANES=8` |
| Waveform (S2) | Captured | accel_busy pulses about 142 / 50 / 89 us; `trap`, `cpu_bus_fault`, `accel_error` stay 0; `firmware_pass` high; `pass_checks` 3, `fail_checks` 0; `chars` 0x20c (524); end cycle 0x48471 |
| Synthesis | Completed | 224 warnings, 82 info, no error or critical-warning categories |
| Firmware in IMEM | Confirmed | `INIT_00` non-zero: `256'h931337B7371337639313376393133763931337639313932303B7B72393B73737` |
| Synthesized utilization (screenshot 4) | Matches run 1 | table 2.1 |
| Implementation | Completed | "Implementation Complete"; Design State Routed |
| Routed timing (screenshot 5) | **Met** | table 2.2 |
| Critical path (screenshot 6) | Captured | table 2.3 |
| Implemented utilization (screenshots 7, 8) | Captured | tables 2.4, 2.5 |
| DRC | **0 errors**, 163 warnings | 2.6 |
| Methodology | **0 critical**, 82 warnings | 2.6 |
| Power estimate (screenshot 9) | Captured | table 2.7 |
| Device view, per-engine colours (screenshot 10, 10b) | Captured | 2.8 |
| Screenshots 1 (Sources) and 2 (top-level RTL schematic) | Captured | 2.9 |
| Bitstream | **Generated** | started 1:28 AM, `top_basys3.bit` modified 1:29 AM, about 2000 KB; `write_bitstream Complete!`, timing unchanged |
| Project archive | Done | saved in `C:\Users\apps\Desktop` (outside AppData) |
| Board programmed (Basys 3) | **Done** | 4:00 PM photo; End of startup status HIGH; DONE LED on |
| UART report on the board | **PASS** | 2.10 |
| System Monitor temperature | **33.3 C measured** | 2.10 |

### 2.1 Synthesis utilization (LANES=8, 50 MHz)

| Resource | Used | Available | Percent | Scripted run 1 |
|---|---:|---:|---:|---:|
| Slice LUTs | 4953 | 20800 | 24% | 4955 |
| Slice registers (FF) | 3612 | 41600 | 9% | 3613 |
| F7 muxes | 65 | 16300 | 1% | |
| Block RAM tiles | 13 | 50 | 26% | 13 |
| DSP48E1 | 68 | 90 | 76% | 68 |
| Bonded IOB | 7 | 106 | 7% | |
| BUFGCTRL / MMCME2_ADV | 1 / 1 | 32 / 5 | | |

### 2.2 Routed timing summary (impl_1, Routed, 50 MHz)

| Check | Value | Required |
|---|---:|---|
| WNS (setup) | **+0.468 ns** | 0 or more |
| TNS | 0.000 ns | 0 |
| **WHS (hold)** | **+0.014 ns** | 0 or more |
| THS | 0.000 ns | 0 |
| WPWS (pulse width) | 3.000 ns | 0 or more |
| Failing endpoints (setup / hold / pulse width) | 0 / 0 / 0 | 0 |
| Endpoints (setup, hold / pulse width) | 14439 / 3745 | |

"All user specified timing constraints are met." **Use WHS = 0.014 ns.** The scripted flow's `metrics.txt` reports "WHS 3.000", which is really the pulse-width slack (script bug, already fixed in the scripts); ignore every scripted "WHS 3.000". An earlier report run under the *synthesized* design (WNS 0.376 / WHS 0.045) is only a post-synthesis estimate and is not the evidence.

### 2.3 Critical path (screenshot 6, routed Path 1)

| Field | Value |
|---|---|
| Slack | +0.468 ns (equals WNS) |
| Source | `u_soc/u_accel_bus/u_accel/u_arch_selector/u_seq_engine/tap_count_q_reg[1]/C` |
| Destination | `.../u_seq_engine/result_o_reg[15]/D` |
| Path group / type | `gen_clk_mmcm.clk_mmcm_out`, Setup (slow process corner) |
| Requirement | 20.000 ns |
| Data path delay | 19.453 ns (logic 12.427 ns = 63.9%, route 7.026 ns = 36.1%) |
| Logic levels | 30 (CARRY4 18, DSP48E1 2, LUT2 4, LUT3 1, LUT4 1, LUT6 3, MUXF7 1) |
| Clock skew / uncertainty | -0.028 ns / 0.082 ns |

Matches the expectation from earlier routed builds. For the report: the sequential engine does its multiply, accumulate, shift and saturate in a single cycle, which limits the SoC to 50 MHz. The pipelined engine alone reaches about 197 MHz (core sweep). The clock path runs `clk_100mhz` pin, IBUF, MMCM, BUFG (fanout 3788).

### 2.4 Implemented utilization, Summary (screenshot 7)

| Resource | Used | Available | Percent | Synthesis |
|---|---:|---:|---:|---:|
| LUT | 4695 | 20800 | 22.57% | 4953 |
| LUTRAM | 44 | 9600 | 0.46% | |
| FF | 3614 | 41600 | 8.69% | 3612 |
| BRAM tiles | 13 | 50 | 26.00% | 13 |
| DSP | 68 | 90 | 75.56% | 68 |
| IO | 7 | 106 | 6.60% | 7 |
| MMCM | 1 | 5 | 20.00% | 1 |

LUT is 258 lower than synthesis because implementation optimization and placement merge and trim logic; BRAM, DSP, IO, MMCM are identical. LANES=8 fits the Basys 3 with 22 DSP slices to spare.

### 2.5 Implemented utilization, Hierarchy (screenshot 8)

| Module | LUT | FF | F7 | BRAM | DSP |
|---|---:|---:|---:|---:|---:|
| `top_basys3` | 4695 | 3614 | 65 | 13 | 68 |
| `u_soc` (nexus32_soc) | 4694 | 3612 | 65 | 13 | 68 |
| `u_accel_bus` | 3690 | 3066 | 65 | 5 | 68 |
| `u_accel` (fir_seq_accel) | 3569 | 2912 | 65 | 4 | 68 |
| `u_arch_selector` | 2591 | 1532 | 62 | 0 | 68 |
| `u_parallel_engine` (PAR) | 1048 | 35 | 0 | 0 | 32 |
| `u_pipelined_engine` (PIPE) | 1182 | 774 | 0 | 0 | 32 |
| `u_seq_engine` (SEQ) | 366 | 157 | 62 | 0 | 4 |
| `u_tap_bram` | 579 | 5 | 0 | 4 | 0 |
| `u_cpu` (picorv32) | 968 | 509 | 0 | 0 | 0 |
| `u_uart_tx` | 23 | 24 | 0 | 0 | 0 |

DSP split 32 + 32 + 4 = 68. PAR has almost no registers but a 994-LUT post-process; PIPE is register-heavy (774 FF) with a 56-LUT post-process; SEQ is smallest (one shared MAC). The CPU's 44 LUT-as-memory cells are its register file. The remaining 8 BRAM tiles outside the accelerator bus are `dmem` (4) and `imem` (4) (names seen in the Methodology report).

### 2.6 DRC and Methodology (routed design)

- **DRC: 163 warnings, 0 errors, 0 critical.** Seen: REQP-1839 rule limit reached (20 violations found; known warning), DSP48E1 pipelining advisories DPIP-1 (7 listed) and DPOP-1 (52 listed). Other entries (35 not DSP-listed plus the rest of the DSP group) were not captured. Warnings do not block the bitstream. The unregistered DSP inputs and outputs are consistent with the 30-level critical path.
- **Methodology: 82 warnings, 0 critical.** LUTAR-1 (1): a LUT drives the async preset pin of the reset synchroniser `reset_sync_q_reg`. SYNTH-6 (13): RAM blocks (`dmem_reg_*`, `imem_rdata_q_reg_*`, `result_mem_reg`, `coefficient_mem_reg_*`) have no merged output register, so timing may be sub-optimal. 68 further synthesis items were not captured. All advisory; RTL is frozen.

### 2.7 Power (Vivado estimate from the routed design, not a measurement)

| Item | Value |
|---|---:|
| Total on-chip power | 0.194 W |
| Dynamic | 0.122 W (63%) |
| Device static | 0.073 W (37%) |
| Junction temperature | 26.0 C |
| Thermal margin | 59.0 C (11.7 W) |
| Ambient assumed / effective thetaJA | 25.0 C / 5.0 C/W |
| Confidence | Medium |

Dynamic breakdown: MMCM 0.106 W (87%), clocks 0.005, signals 0.004, logic 0.003, BRAM 0.002, DSP 0.001, I/O 0.001 W. **Power is dominated by clock generation.** It is a vectorless estimate, so do not use it to compare the three engines. Junction temperature is ambient plus a tiny draw; the measured die temperature comes from System Monitor on the board.

### 2.8 Device view colours (screenshot 10, legend in 10b)

Red = `u_seq_engine`, purple = `u_parallel_engine`, yellow = `u_pipelined_engine`, blue = `u_tap_bram`, green = `u_cpu`. Teal outlines are uncoloured cells (UART, bus glue, top level). Logic sits in clock regions X0Y1, X1Y1, X1Y0. PAR and PIPE spread into narrow strips because each needs 32 DSP slices from the DSP columns. Note: an empty chip-outline Device view (the synthesized design) is not usable as screenshot 10.

### 2.9 Screenshots 1 and 2

- **Screenshot 1 (Sources, Hierarchy):** `top_basys3` > `u_soc` (nexus32_soc) > `u_uart_tx`, `u_cpu` (picorv32), `u_accel_bus` > `u_accel` (fir_seq_accel) > `u_tap_bram`, `u_arch_selector` > `u_seq_engine`, `u_parallel_engine`, `u_pipelined_engine`. The `xil_defaultlib.*_MUST_BE_*` entries are parameter-guard modules for LANES and SYS_CLK_MHZ; valid values (8, 50) are in use and synthesis and implementation passed.
- **Screenshot 2 (elaborated top level):** 10 cells, 7 I/O ports, 24 nets. Inputs `clk_100mhz`, `btn_center`; outputs `led[3:0]`, `uart_tx`; MMCM, BUFG, reset synchroniser and one `u_soc` block.

### 2.10 Board results (Basys 3, LANES=8, 50 MHz)

| Item | Result | Expected |
|---|---|---|
| Board label | BASYS 3 (Digilent, Xilinx University Program) | Basys 3 |
| Connection | COM11, hw_target `xilinx_tcf/Digilent/210183B7AF46A`, `xc7a35t_0` | |
| Programming | `top_basys3.bit` programmed; "End of startup status: HIGH"; no debug cores (normal) | |
| LEDs | DONE on, **LD0 ON, LD1 OFF, LD2 ON, LD3 OFF** | ON / OFF / ON / OFF |
| UART build line | `LANES=8 CLK_MHZ=50 TAP_COUNT=8 SAMPLE_COUNT=1024 golden_checksum=0xb2be7f16` | LANES=8, 50 MHz |
| SEQ | `check=PASS`, `cycles_total=14352`, `compute_cycles=14332`, `result_count=1024`, checksum `0xb2be7f16`, status `0x00000002` | 14352 |
| PAR | `check=PASS`, `cycles_total=5136`, `compute_cycles=5116`, `result_count=1024`, checksum `0xb2be7f16`, status `0x00000002` | 5136 |
| PIPE | `check=PASS`, `cycles_total=9232`, `compute_cycles=9212`, `result_count=1024`, checksum `0xb2be7f16`, status `0x00000002` | 9232 |
| Final line | **`NEXUS32 RESULT: PASS`** (the firmware repeats the report; five copies on screen, **82 copies in `uart_log.txt`, all identical, 82 x PASS, 0 x FAIL**) | PASS |
| Die temperature (System Monitor, measured) | **33.3 C** at 4:07 PM (chart about 32 to 34.5 C over roughly a minute) | |

The board cycle counts equal the LANES=8 simulation, and `CLK_MHZ=50` confirms the 50 MHz build is the one running. The simulation printed `CLK_MHZ=100` only because the testbench clock is fixed at 100 MHz. The measured 33.3 C is above the Vivado junction estimate (26.0 C), which assumed 25 C ambient and a tiny power draw; they are different kinds of numbers.

Harmless simulation warnings: `glbl` has no `LANES` parameter; `gen_tree[3].val_q` used before declaration (`fir_pipelined_engine.sv:91`, VRFC 10-8913); "not all objects being logged". The testbench hardcodes a 100 MHz clock, so the simulated build line prints `CLK_MHZ=100`; on the board it should print `CLK_MHZ=50`. Cycle counts do not depend on clock frequency.

## 3. Screenshot checklist

| # | Screenshot | State |
|---|---|---|
| 1 | Sources hierarchy (`top_basys3`, `u_soc`, engines) | Have |
| 2 | Top-level RTL schematic with ports (`clk_100mhz`, `btn_center`, `led[3:0]`, `uart_tx`) | Have |
| 3 | RTL schematic inside `u_soc` | Have (also `schematic_u_soc.pdf`) |
| 4 | Synthesized utilization | Have (Hierarchy view) |
| 5 | Routed Design Timing Summary | Have |
| 6 | Critical path | Have |
| 7, 8 | Implemented utilization, Summary and Hierarchy | Have |
| DRC, Methodology | Reports | Have |
| 9 | Power summary (estimate) | Have |
| 10, 10b | Device view per engine, colour legend | Have |
| 11 | System Monitor die temperature (measured) | Have (33.3 C) |
| 12 | UART report | Have (`NEXUS32 RESULT: PASS`) |
| S1 | Simulation console: 3 `check=PASS` + `NEXUS32 RESULT: PASS` | **Not captured** (optional). The first attempt to re-run only ran the default 1000 ns; the testbench needs `run all` (about 2.96 ms). The board UART log covers the same proof. |
| S2 | Simulation waveform | Have |
| + | Phone photos: board label, LD0 and LD2 on, LD3 off, DONE on | Have (a wider shot of the whole board is optional) |

`NEXUS32_screenshots_interim.pdf` (22 pages) holds an index page plus 1, 2, 3, 4, 5, 6, 7, 8, DRC, Methodology, 9, 9b (power supply), 10, 10b, BS (bitstream / Design Runs), HW (Hardware Manager), 11, 12, S2 and two board photos.

## 4. What is left

Nothing is required. Optional extras, only if someone wants a more polished package:

1. **S1:** in Vivado run the behavioral simulation, type `run all` in the Tcl Console (it runs about 2.96 ms), and capture the console showing three `arch=... check=PASS` lines, `NEXUS32 RESULT: PASS` and `PASS: board demo firmware LANES=8`. Not needed for the verdict.
2. A wide phone photo of the whole board with LD0 and LD2 on, LD3 off and the DONE LED lit.
3. Copy `top_basys3.bit` (about 2.08 MB, in `...\nexus32_gui.runs\impl_1\`) next to the project archive on the Desktop.

Vccint (estimate): 0.026 A total at 1.000 V (0.015 dynamic, 0.010 static); Vccaux 0.071 A (the MMCM rail).

## 5. Board results versus expectation

| Item | Expected | Measured on the board |
|---|---|---|
| UART `cycles_total` SEQ / PAR / PIPE | 14352 / 5136 / 9232 | 14352 / 5136 / 9232 |
| UART result line | `NEXUS32 RESULT: PASS` | `NEXUS32 RESULT: PASS` |
| UART build line | `LANES=8 CLK_MHZ=50` | `LANES=8 CLK_MHZ=50 TAP_COUNT=8 SAMPLE_COUNT=1024` |
| LEDs LD0 / LD1 / LD2 / LD3 | ON / OFF / ON / OFF | ON / OFF / ON / OFF |

**LD2 alone is not proof:** it lights on firmware PASS **or** on `accelerator_done`. The UART line `NEXUS32 RESULT: PASS` is the proof.

## 6. Open items and cautions

1. **Board label confirmed: BASYS 3.** (done)
2. **LANES=16 and 32 simulations:** the command-line run included them but the output was not seen. Expected from the repo: SEQ/PAR/PIPE 22560/5152/10272 (16) and 38976/5184/11328 (32). They do not fit the board.
3. **Thin margins: setup +0.468 ns, hold +0.014 ns.** Both pass. Do not change settings or rerun synthesis or implementation. If anything is rerun, recheck WNS and WHS before generating the bitstream.
4. The guide has not been fully clicked through in the GUI; menu names may differ slightly in 2024.2. The scripted flow (`vivado\*.bat`: `PROGRAM_BOARD.bat`, `READ_UART.bat`, `COLLECT_EVIDENCE.bat`) remains the formal evidence path.
5. The repo's `docs/STATUS.md` (2026-11-10) still says no Vivado utilization, timing or board evidence exists; this run produces the first of it.
6. DRC and Methodology warnings are advisory (DPIP/DPOP unregistered DSP, REQP-1839, SYNTH-6, LUTAR-1). They are consistent with the 50 MHz limit and need no action on frozen RTL.

## 7. Values table (update as you go)

| Item | Value |
|---|---|
| Vivado version | 2024.2 |
| LANES / SYS_CLK_MHZ | 8 / 50 |
| Synthesis time / implementation time | not recorded |
| WNS / TNS / WHS / THS (ns), routed | 0.468 / 0.000 / **0.014** / 0.000 |
| LUT / FF / DSP / BRAM, synthesis | 4953 / 3612 / 68 / 13 |
| LUT / FF / DSP / BRAM, implemented | 4695 / 3614 / 68 / 13 |
| Critical path: source, destination, levels, delay | `tap_count_q_reg[1]` to `result_o_reg[15]` (SEQ), 30 levels, 19.453 ns |
| Total / dynamic / static power (W), estimate | 0.194 / 0.122 / 0.073 |
| MMCM share of dynamic power | 0.106 W (87%) |
| Junction temperature (C), estimate | 26.0 |
| DRC / Methodology | 0 errors, 163 warnings / 0 critical, 82 warnings |
| Vccint current (A), estimate | 0.026 A total at 1.000 V (dynamic 0.015, static 0.010); Vccaux 0.071 A (MMCM), Vccbram 0.001 A |
| Bitstream start / end time | 1:28 AM / .bit file written 1:29 AM (about 1 minute); completion confirmed on screen at 1:31 AM (write_bitstream Complete!, impl_1 WNS 0.468, WHS 0.014, 0 failed routes, 82 methodology warnings) |
| Die temperature (C), measured on board | **33.3** (System Monitor, 4:07 PM) |
| UART SEQ / PAR / PIPE `cycles_total` | **14352 / 5136 / 9232** |
| UART result line | **`NEXUS32 RESULT: PASS`** |
| LEDs LD0 / LD1 / LD2 / LD3 | **ON / OFF / ON / OFF** (DONE on) |

## 8. Files this status refers to

- `nexus32-vivado-e17d20b.zip`: source bundle (RTL in `rtl/`, firmware in `firmware/`, constraints in `constraints/basys3.xdc`, scripts in `vivado/`, docs in `docs/`).
- `NEXUS32_VIVADO_PROJECT_GUIDE.md`: the A-to-Z GUI procedure (this status follows its numbering).
- `NEXUS32_REVIEW_FOR_CHAKSHU.md`: the review notes; wins on any disagreement.
- `NEXUS32_screenshots_interim.pdf` and `schematic_u_soc.pdf`: screenshots collected so far.
- `VIVADO_RUN_CHECKLIST.md` and `docs/VIVADO_DAY.md`: earlier scripted and board-day checklists.

## 9. How the run went (timeline, all 2026-11-13 local time from screenshot clocks)

| Time | Event |
|---|---|
| earlier | Scripted command-line xsim at LANES=4 and 8 passed (bundle `2f87f96`); GUI project `nexus32_gui` created at the AppData path; guide followed |
| 12:12 AM | GUI behavioral simulation, LANES=8: PASS; waveform S2 captured |
| 12:35 AM | Synthesis complete; synthesized utilization (4953 / 3612 / 68 / 13); firmware `INIT_00` confirmed non-zero |
| 12:36 to 12:41 AM | Implementation; routed design 12:41 |
| 12:43 / 12:49 / 12:50 AM | Device view (single colour); routed timing summary (WNS 0.468, WHS 0.014); power estimate |
| 1:05 AM | Critical path: `u_seq_engine` `tap_count_q_reg[1]` to `result_o_reg[15]`, 19.453 ns, 30 levels |
| 1:06 to 1:14 AM | Implemented utilization summary and hierarchy (engines expanded) |
| 1:09 / 1:12 AM | DRC (163 warnings, 0 errors) and Methodology (82 warnings, 0 critical) |
| 1:20 AM | Per-engine coloured device view and Netlist colour legend |
| 1:26 AM | Power Supply table (Vccint 0.026 A) |
| 1:28 / 1:29 / 1:31 AM | Bitstream started / `top_basys3.bit` written / completion seen in Design Runs; project archived to `C:\Users\apps\Desktop` |
| 1:39 to 1:43 AM | Screenshot 1 (Sources) and screenshot 2 (top-level RTL schematic) |
| 3:42 PM | Board in hand: label BASYS 3, red power LED on, COM11 |
| 3:46 / 3:54 PM | Hardware Manager connected (`xc7a35t_0`, DONE 0); Program Device dialog with `top_basys3.bit` |
| about 3:55 PM | Programmed: "End of startup status: HIGH" |
| 4:00 PM | LED photo: DONE on, LD0 on, LD1 off, LD2 on, LD3 off |
| 4:04 PM | UART on COM11 (PuTTY, 115200 8N1), BTNC pressed: `NEXUS32 RESULT: PASS` |
| 4:07 PM | System Monitor: 33.3 C measured |
| 4:10 PM | `uart_log.txt` saved: 574 lines, 82 identical reports, 82 x PASS, 0 x FAIL |
| 4:14 PM | Attempt to capture S1: simulation re-run only reached 1000 ns (needs `run all`); not completed |

### Decisions and corrections made along the way

1. **Project path:** the project is under `C:\Users\apps\AppData\Roaming\Xilinx\Vivado\nexus32_gui\`, not `C:\nexus32_gui`. The folder `C:\nexus32_gui\screenshots\` does not exist.
2. **Hold slack:** use the GUI value WHS = 0.014 ns. The scripted `metrics.txt` "WHS 3.000" is really the pulse-width slack (script bug, already fixed in the scripts).
3. **Synthesized versus routed timing:** one timing report was first run under the synthesized design (WNS 0.376, WHS 0.045). It was identified as the wrong report; the routed one (Design State Routed, header IMPLEMENTED DESIGN) is the evidence.
4. **Empty Device view:** the synthesized-design Device view is only the chip outline and was rejected; the implemented one (single colour, later per engine) is used.
5. **Power:** vectorless estimate dominated by the MMCM (87% of dynamic); not for comparing engines. Junction temperature 26.0 C is an estimate; 33.3 C from System Monitor is a measurement.
6. **REQP-1839:** appeared as "rule limit reached, 20 violations". The review notes list it as a known, harmless warning; Chakshu's reading that it relates to BRAM control pins was never confirmed (the 20 entries were not opened).
7. **Testbench file** `C:/nexus32/tests/rtl/tb_nexus32_soc_demo.sv` was open in the editor during the later steps. It was never edited (Save greyed out); its `LANES = 32` is only the default and was overridden to 8 for the run (the waveform shows `LANES = 8`).
8. **UART repeats:** the firmware repeats the report continuously; the first screen copies wrapped only because the window was narrower.
9. **LD2** alone does not prove a pass; the UART line does.

## 10. Not captured or not seen (ask Chakshu if you need any of these)

| Item | Why it matters | How Chakshu can get it |
|---|---|---|
| S1: simulation console text | Optional proof; covered by the UART log | Run simulation, Tcl Console `run all`, screenshot the last lines |
| Remaining DRC entries (about 35 non-DSP rows plus the rest of the DSP group) and the 20 REQP-1839 entries | To confirm what REQP-1839 refers to | Vivado DRC tab: expand the Netlist branch and screenshot; or send `top_basys3_drc_routed.rpt` |
| Remaining Methodology entries (68 more under Synthesis) | Completeness only | Methodology tab, scroll and screenshot; or the methodology report file |
| Full Vivado report files (timing, utilization, power, DRC) | Exact numbers, full critical-path text | In `...\nexus32_gui.runs\impl_1\` (typically `top_basys3_timing_summary_routed.rpt`, `top_basys3_utilization_placed.rpt`, `top_basys3_power_routed.rpt`, `top_basys3_drc_routed.rpt`; names may differ slightly) |
| Run logs | Synthesis and implementation run times, warnings by id | `runme.log` in `synth_1` and `impl_1` folders |
| Synthesis and implementation durations | Values table says "not recorded" | Design Runs tab or the run logs |
| LANES=16 and 32 simulation output | Repo regression match (expected 22560/5152/10272 and 38976/5184/11328) | Re-run command-line xsim or send the earlier console text |
| Wider board photo | Cleaner evidence photo | Phone shot of the whole board, only if the board is available again |
| Project archive and `top_basys3.bit` | Reproducibility | Archive zip is on Chakshu's Desktop; `.bit` is in the `impl_1` folder |
| `schematic_u_soc.pdf` | Full-size version of screenshot 3 | Held by Chakshu |

Nothing else known to be missing. If you spot an inconsistency between this file and the PDF captions or `uart_log.txt`, tell Chakshu before reporting numbers onward.

