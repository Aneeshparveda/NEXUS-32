# PicoRV32 vendoring and integration pin

NEXUS-32 uses upstream `YosysHQ/picorv32` at exact commit `ef203c2b0a3fb793280f5114941416c425c5b461`.

Run `bash scripts/vendor_picorv32.sh` to clone upstream, check out the full commit hash, verify the resolved `HEAD`, and copy `picorv32.v`, `COPYING`, and a revision record into `vendor/picorv32/`. The vendor directory deliberately has no nested `.git` repository.

The CPU baseline is RV32I: compressed instructions, M extension, fast multiplier, and divider are disabled. Counters, zeroed initial registers, reset address `0x00000000`, IRQ vector `0x00000010`, IRQ support, and stack address `0x00014000` are configured. External IRQ inputs are tied low in this smoke milestone; IRQ peripherals and firmware policy remain future work.

## Memory map in the CPU smoke SoC

- IMEM: `0x00000000..0x00003fff` (16 KiB, CPU read-only)
- DMEM: `0x00010000..0x00013fff` (16 KiB, byte-write strobes supported)
- Coefficients: `0x00020000..0x00020fff`
- Sample A: `0x00021000..0x00021fff`
- Result: `0x00022000..0x00022fff` (CPU read-only)
- Accelerator CSRs: `0x10005000..0x10005fff`

The smoke firmware loads a four-tap Q16.16 vector, launches the sequential engine, polls sticky DONE, reads `0x00022000`, checks `0x00020000` (2.0 in Q16.16), and writes a PASS sentinel to DMEM.

## Known boundary

This is a single-core milestone: no DMA, UART, GPIO, timer/IRQ controller, Sample B, stream double buffer, or full debug-monitor CSRs. PicoRV32's native memory interface has no dedicated bus-error input; the bridge exposes sticky fault status and returns zero on errored MMIO reads. Vivado synthesis, BRAM inference, timing, utilization, and bitstream generation remain unverified.
