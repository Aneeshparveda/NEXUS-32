#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/rtl

TARGET_LANES="${1:-all}"

run_parallel() {
  local lanes="$1"
  echo "--- Testing fir_parallel_engine LANES=${lanes} ---"
  iverilog -g2012 -Wall -s tb_fir_parallel_engine \
    -P tb_fir_parallel_engine.LANES="${lanes}" \
    -o "results/rtl/tb_fir_parallel_engine_l${lanes}.vvp" \
    rtl/fir_q16_postprocess.sv \
    rtl/fir_parallel_engine.sv \
    tests/rtl/tb_fir_parallel_engine.sv
  vvp "results/rtl/tb_fir_parallel_engine_l${lanes}.vvp"
}

if [[ "${TARGET_LANES}" == "all" ]]; then
  for l in 4 8 16 32; do
    run_parallel "$l"
  done
else
  run_parallel "${TARGET_LANES}"
fi

