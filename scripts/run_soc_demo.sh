#!/usr/bin/env bash
# UART transmitter unit test plus the end-to-end board demo firmware on the
# PicoRV32 SoC for LANES 4, 8, 16 and 32 (or the one given as $1).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/rtl
TARGET_LANES="${1:-all}"

for div in 2 5 16; do
  iverilog -g2012 -Wall -s tb_nexus32_uart_tx \
    -P tb_nexus32_uart_tx.CLKS_PER_BIT="${div}" \
    -o "results/rtl/tb_nexus32_uart_tx_d${div}.vvp" \
    rtl/nexus32_uart_tx.sv tests/rtl/tb_nexus32_uart_tx.sv
  vvp "results/rtl/tb_nexus32_uart_tx_d${div}.vvp"
done

bash scripts/build_demo_firmware.sh

run_demo() {
  local lanes="$1"
  echo "--- board demo firmware, LANES=${lanes} ---"
  iverilog -g2012 -Wall -s tb_nexus32_soc_demo \
    -P tb_nexus32_soc_demo.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_soc_demo_l${lanes}.vvp" \
    vendor/picorv32/picorv32.v \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    rtl/nexus32_uart_tx.sv rtl/nexus32_soc.sv tests/rtl/tb_nexus32_soc_demo.sv
  vvp "results/rtl/tb_nexus32_soc_demo_l${lanes}.vvp"
}

if [[ "${TARGET_LANES}" == "all" ]]; then
  for lanes in 4 8 16 32; do
    run_demo "$lanes"
  done
else
  run_demo "${TARGET_LANES}"
fi
echo "ALL NEXUS-32 UART AND BOARD DEMO TESTS PASSED"
