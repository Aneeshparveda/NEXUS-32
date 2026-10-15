#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/rtl

TARGET_LANES="${1:-all}"

run_selector() {
  local lanes="$1"
  echo "--- Testing fir_arch_selector LANES=${lanes} ---"
  iverilog -g2012 -s tb_fir_arch_selector \
    -P tb_fir_arch_selector.LANES="${lanes}" \
    -o "results/rtl/tb_fir_arch_selector_l${lanes}.vvp" \
    rtl/fir_q16_mac.sv \
    rtl/fir_q16_postprocess.sv \
    rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv \
    rtl/fir_pipelined_engine.sv \
    rtl/fir_arch_selector.sv \
    tests/rtl/tb_fir_arch_selector.sv
  vvp "results/rtl/tb_fir_arch_selector_l${lanes}.vvp"
}

if [[ "${TARGET_LANES}" == "all" ]]; then
  for l in 4 8 16 32; do
    run_selector "$l"
  done
else
  run_selector "${TARGET_LANES}"
fi

