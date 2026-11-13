# Live demo page

`nexus32_live_demo.html` is a single-file, offline page for presenting NEXUS-32. Open it in Chrome or Edge, straight from disk.

1. **Signal lab:** a noisy ECG, sine or two-tone signal, cleaned by a Q16.16 FIR that uses the hardware's exact arithmetic. It checks against `golden_model.fir_block_q16_16`.
2. **The race:** the CPU alone (the software baseline from `experiments/sw_baseline/`) against the SEQ, PAR and PIPE engines at 4/8/16/32 taps, plus a "who wins at its own Fmax" twist. The Fmax values are out-of-context synthesis estimates.
3. **Live board:** reads the Basys 3 UART over Web Serial (115200 8N1) and parses the board demo report. It can also replay the 2026-11-13 board log (`results/board_2026-11-13/uart_log.txt`).

Every number is labelled as a simulation, an estimate, or measured on the board. Close any terminal program before you click **Connect**, because only one program can use the COM port.
