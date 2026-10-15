#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p results/rtl

iverilog -g2012 -Wall -s tb_fir_q16_primitives \
  -o results/rtl/tb_fir_q16_primitives.vvp \
  rtl/fir_q16_mac.sv \
  rtl/fir_q16_postprocess.sv \
  tests/rtl/tb_fir_q16_primitives.sv
vvp results/rtl/tb_fir_q16_primitives.vvp

iverilog -g2012 -Wall -s tb_fir_seq_engine \
  -o results/rtl/tb_fir_seq_engine.vvp \
  rtl/fir_q16_mac.sv \
  rtl/fir_q16_postprocess.sv \
  rtl/fir_seq_engine.sv \
  tests/rtl/tb_fir_seq_engine.sv
vvp results/rtl/tb_fir_seq_engine.vvp

iverilog -g2012 -Wall -s tb_fir_seq_sync_source \
  -o results/rtl/tb_fir_seq_sync_source.vvp \
  rtl/fir_q16_mac.sv \
  rtl/fir_q16_postprocess.sv \
  rtl/fir_seq_engine.sv \
  tests/rtl/tb_fir_seq_sync_source.sv
vvp results/rtl/tb_fir_seq_sync_source.vvp

iverilog -g2012 -Wall -s tb_fir_tap_bram \
  -o results/rtl/tb_fir_tap_bram.vvp \
  rtl/fir_tap_bram.sv \
  tests/rtl/tb_fir_tap_bram.sv
vvp results/rtl/tb_fir_tap_bram.vvp

iverilog -g2012 -Wall -s tb_fir_seq_accel \
  -o results/rtl/tb_fir_seq_accel.vvp \
  rtl/fir_q16_mac.sv \
  rtl/fir_q16_postprocess.sv \
  rtl/fir_seq_engine.sv \
  rtl/fir_tap_bram.sv \
  rtl/fir_seq_accel.sv \
  tests/rtl/tb_fir_seq_accel.sv
vvp results/rtl/tb_fir_seq_accel.vvp

iverilog -g2012 -Wall -s tb_nexus32_accel_bus \
  -o results/rtl/tb_nexus32_accel_bus.vvp \
  rtl/fir_q16_mac.sv \
  rtl/fir_q16_postprocess.sv \
  rtl/fir_seq_engine.sv \
  rtl/fir_tap_bram.sv \
  rtl/fir_seq_accel.sv \
  rtl/nexus32_accel_bus.sv \
  tests/rtl/tb_nexus32_accel_bus.sv
vvp results/rtl/tb_nexus32_accel_bus.vvp
