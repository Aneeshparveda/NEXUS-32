#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/rtl

TARGET_LANES="${1:-all}"

run_pipelined() {
  local lanes="$1"
  echo "--- Testing fir_pipelined_engine LANES=${lanes} ---"
  iverilog -g2012 -Wall -s tb_fir_pipelined_engine \
    -P tb_fir_pipelined_engine.LANES="${lanes}" \
    -o "results/rtl/tb_fir_pipelined_engine_l${lanes}.vvp" \
    rtl/fir_q16_postprocess.sv \
    rtl/fir_pipelined_engine.sv \
    tests/rtl/tb_fir_pipelined_engine.sv
  vvp "results/rtl/tb_fir_pipelined_engine_l${lanes}.vvp"
}

if [[ "${TARGET_LANES}" == "all" ]]; then
  for l in 4 8 16 32; do
    run_pipelined "$l"
  done
else
  run_pipelined "${TARGET_LANES}"
fi

