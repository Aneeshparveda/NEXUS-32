#!/usr/bin/env bash
# Build the software FIR baseline and run it on the SoC at LANES=4/8/16/32.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/gen_demo_expected.py build/nexus32_demo_expected.inc >/dev/null
D=""; for t in 4 8 16 32; do v=$(grep "EXPECT_CHK_T$t," build/nexus32_demo_expected.inc | sed 's/.*, *//'); D="$D -DCHK_T$t=${v}u"; done
riscv64-elf-gcc -march=rv32i -mabi=ilp32 -O2 -mno-relax -nostdlib -nostartfiles $D \
  -Wl,--no-relax -Wl,-T,firmware/nexus32_smoke.ld experiments/sw_baseline/sw_fir.c -lgcc \
  -o experiments/sw_baseline/sw_fir.elf
riscv64-elf-objcopy -O binary experiments/sw_baseline/sw_fir.elf experiments/sw_baseline/sw_fir.bin
python3 scripts/bin_to_memh.py experiments/sw_baseline/sw_fir.bin experiments/sw_baseline/sw_fir.hex 4096
riscv64-elf-size experiments/sw_baseline/sw_fir.elf | tail -1
for L in ${@:-4 8 16 32}; do
  iverilog -g2012 -s tb_swfir -P tb_swfir.LANES=$L -o experiments/sw_baseline/sim_l$L.vvp \
    vendor/picorv32/picorv32.v rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv rtl/fir_tap_bram.sv \
    rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv rtl/nexus32_uart_tx.sv rtl/nexus32_soc.sv \
    experiments/sw_baseline/tb_swfir.sv
  echo "--- LANES=$L"; vvp experiments/sw_baseline/sim_l$L.vvp | grep -E "SWFIR|FAIL"
done
