#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/rtl
iverilog -g2012 -Wall -s tb_fir_parallel_engine \
  -o results/rtl/tb_fir_parallel_engine.vvp \
  rtl/fir_q16_postprocess.sv \
  rtl/fir_parallel_engine.sv \
  tests/rtl/tb_fir_parallel_engine.sv
vvp results/rtl/tb_fir_parallel_engine.vvp
