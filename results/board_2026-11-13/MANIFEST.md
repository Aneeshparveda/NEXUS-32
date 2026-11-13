# Board run 2026-11-13: evidence manifest

The first hardware run of NEXUS-32: the full SoC on a Digilent Basys 3. Every value here is copied from a Vivado screen, a Vivado file or the board. Nothing is estimated unless it is labelled as an estimate.

## What was built

| Item | Value |
|---|---|
| Source | Bundle `nexus32-vivado-e17d20b.zip` (commit `e17d20b`, clean); RTL, testbench and firmware are identical to `2f87f96` |
| Flow | Vivado 2024.2 GUI project (not the scripted flow), default synthesis and implementation strategies |
| Part | `xc7a35tcpg236-1` (Basys 3) |
| Top / generics | `top_basys3`, `LANES=8`, `SYS_CLK_MHZ=50`, `IMEM_INIT_FILE="C:/nexus32/firmware/nexus32_demo.hex"` |
| Constraints | `constraints/basys3.xdc` |
| Bitstream | `top_basys3.bit`, header `top_basys3;UserID=0XFFFFFFFF;Version=2024.2`, part `7a35tcpg236`, built 2026/11/13 01:29:19, 2,192,118 bytes |
| Bitstream SHA-256 | `47778f086f2dbdc5f28398d9971b84cd960760fddf56c5cefc4eb3de6ce6f43d` |

The bitstream itself is not committed (`*.bit` is ignored). Keep it with the project archive.

## Results

| Check | Result | Source |
|---|---|---|
| Behavioral simulation (xsim, LANES=8) | PASS: SEQ / PAR / PIPE `cycles_total` 14352 / 5136 / 9232, checksum `0xb2be7f16` | `screenshots.pdf` (S2) |
| Routed timing at 50 MHz | **Met.** WNS +0.468 ns, TNS 0, WHS +0.014 ns, THS 0, WPWS 3.000 ns; 0 failing endpoints (14439 setup/hold, 3745 pulse width) | `screenshots.pdf` (5, BS) |
| Critical path | `u_seq_engine/tap_count_q_reg[1]` to `u_seq_engine/result_o_reg[15]`, 19.453 ns (logic 12.427 / route 7.026), 30 logic levels (18 CARRY4, 2 DSP48E1) | `screenshots.pdf` (6) |
| Utilization (implemented) | 4695 LUT (22.6%), 3614 FF (8.7%), 68/90 DSP48E1 (75.6%), 13/50 BRAM tiles, 7 IO, 1 MMCM | `screenshots.pdf` (7) |
| DSP split | PAR 32, PIPE 32, SEQ 4 | `screenshots.pdf` (8) |
| DRC / Methodology | 0 errors, 163 warnings / 0 critical, 82 warnings | `screenshots.pdf` (DRC, Meth) |
| Programming | "End of startup status: HIGH", DONE LED on | `screenshots.pdf` (HW, board photos) |
| LEDs | LD0 on, LD1 off, LD2 on, LD3 off | Board photos |
| UART (COM11, 115200 8N1) | Build line `LANES=8 CLK_MHZ=50 TAP_COUNT=8 SAMPLE_COUNT=1024`; SEQ / PAR / PIPE `check=PASS`, `cycles_total` **14352 / 5136 / 9232**, identical to simulation | `uart_log.txt` |
| UART repeat count | 82 reports, 82 x `NEXUS32 RESULT: PASS`, 0 FAIL. 61 reports are complete; 21 were cut at 80 columns by the terminal window, so their checksum fields are missing. The cycle counts never change. | `uart_log.txt` |
| Die temperature | **33.3 °C measured** (System Monitor / XADC, 4:07 PM; about 32 to 34.5 °C over one minute) | `screenshots.pdf` (11) |
| Power | **Estimate:** 0.194 W total (0.122 dynamic, 0.073 static); MMCM 0.106 W = 87% of dynamic; junction 26.0 °C; confidence Medium. Vccint 0.026 A, Vccaux 0.071 A | `screenshots.pdf` (9, 9b) |

## Known warnings (advisory, frozen RTL)

- **DPIP-1, DPOP-1:** DSP48E1 inputs and outputs are not registered. This is consistent with the 30-level critical path, and it is why the SoC runs at 50 MHz, not 100.
- **REQP-1839:** a register with an asynchronous reset drives the BRAM control pins. A reset during a memory access could corrupt memory. Press BTNC only while the board is idle.
- **LUTAR-1:** the reset synchronizer's asynchronous preset is driven by a LUT (`btn_center || !clk_locked`), so a glitch could reset the SoC.
- **SYNTH-6:** the RAM blocks have no merged output register.
- **7-segment display:** it lights as "8.8.8.8" because the design does not drive those pins and Vivado pulls unused pins low. This is cosmetic.

## Not captured

The simulation console screenshot (S1, optional; the UART log covers it), the full Vivado report files, the run logs, the remaining DRC and Methodology entries, and the LANES=16 and 32 simulation output. Chakshu can still fetch everything from the laptop except new board steps.

## Files

- `uart_log.txt`: terminal text from the board (a copy from the PuTTY window, not a raw serial capture).
- `screenshots.pdf`: 22 captioned pages with an index on page 1.
- `PROGRESS_STATUS.md`: Chakshu's full run status and timeline.

Run by Chakshu, on Vivado 2024.2 and Windows, 2026-11-12 to 13.
