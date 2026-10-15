#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/rtl
iverilog -g2012 -Wall -s tb_fir_accel_architectures \
  -o results/rtl/tb_fir_accel_architectures.vvp \
  rtl/fir_q16_mac.sv \
  rtl/fir_q16_postprocess.sv \
  rtl/fir_seq_engine.sv \
  rtl/fir_parallel_engine.sv \
  rtl/fir_pipelined_engine.sv \
  rtl/fir_arch_selector.sv \
  rtl/fir_tap_bram.sv \
  rtl/fir_seq_accel.sv \
  tests/rtl/tb_fir_accel_architectures.sv
vvp results/rtl/tb_fir_accel_architectures.vvp
