#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/rtl
TARGET_LANES="${1:-all}"

run_diff_lane() {
  local lanes="$1"
  echo "--- Testing 3-way differential FIR LANES=${lanes} ---"
  iverilog -g2012 -Wall -s tb_fir_differential \
    -P tb_fir_differential.LANES="${lanes}" \
    -o "results/rtl/tb_fir_differential_l${lanes}.vvp" \
    rtl/fir_q16_mac.sv \
    rtl/fir_q16_postprocess.sv \
    rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv \
    rtl/fir_pipelined_engine.sv \
    tests/rtl/tb_fir_differential.sv
  vvp "results/rtl/tb_fir_differential_l${lanes}.vvp"
}

if [[ "${TARGET_LANES}" == "all" ]]; then
  for l in 4 8 16 32; do
    run_diff_lane "$l"
  done
else
  run_diff_lane "${TARGET_LANES}"
fi

echo "ALL DIFFERENTIAL SMOKE TESTS PASSED"
