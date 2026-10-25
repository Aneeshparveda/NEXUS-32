#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build_subword_firmware.sh
mkdir -p results/rtl
iverilog -g2012 -Wall -s tb_nexus32_soc_subword \
  -o results/rtl/tb_nexus32_soc_subword.vvp \
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
  tests/rtl/tb_nexus32_soc_subword.sv
vvp results/rtl/tb_nexus32_soc_subword.vvp
