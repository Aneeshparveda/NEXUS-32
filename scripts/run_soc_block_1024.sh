#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_LANES="${1:-all}"
bash scripts/build_block_1024_firmware.sh
mkdir -p results/rtl

run_lane() {
  local lanes="$1"
  echo "--- Testing CPU-driven 1024-sample block LANES=${lanes} ---"
  iverilog -g2012 -Wall -s tb_nexus32_soc_block_1024 \
    -P tb_nexus32_soc_block_1024.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_soc_block_1024_l${lanes}.vvp" \
    vendor/picorv32/picorv32.v \
    rtl/fir_q16_mac.sv \
    rtl/fir_q16_postprocess.sv \
    rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv \
    rtl/fir_pipelined_engine.sv \
    rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv \
    rtl/fir_seq_accel.sv \
    rtl/nexus32_accel_bus.sv \
    rtl/nexus32_soc.sv \
    tests/rtl/tb_nexus32_soc_block_1024.sv
  vvp "results/rtl/tb_nexus32_soc_block_1024_l${lanes}.vvp"
}

if [[ "$TARGET_LANES" == "all" ]]; then
  for lanes in 4 8 16 32; do
    run_lane "$lanes"
  done
else
  run_lane "$TARGET_LANES"
fi
