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
  rtl/fir_parallel_engine.sv \
  rtl/fir_pipelined_engine.sv \
  rtl/fir_arch_selector.sv \
  rtl/fir_tap_bram.sv \
  rtl/fir_seq_accel.sv \
  tests/rtl/tb_fir_seq_accel.sv
vvp results/rtl/tb_fir_seq_accel.vvp

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

# Reach the existing lane-sweep benches through the canonical RTL smoke path;
# each script remains the source of its own compile list and output naming.
bash scripts/run_selector_smoke.sh all
bash scripts/run_parallel_smoke.sh all
bash scripts/run_pipelined_smoke.sh all

iverilog -g2012 -Wall -s tb_nexus32_accel_bus \
  -o results/rtl/tb_nexus32_accel_bus.vvp \
  rtl/fir_q16_mac.sv \
  rtl/fir_q16_postprocess.sv \
  rtl/fir_seq_engine.sv \
  rtl/fir_parallel_engine.sv \
  rtl/fir_pipelined_engine.sv \
  rtl/fir_arch_selector.sv \
  rtl/fir_tap_bram.sv \
  rtl/fir_seq_accel.sv \
  rtl/nexus32_accel_bus.sv \
  tests/rtl/tb_nexus32_accel_bus.sv
vvp results/rtl/tb_nexus32_accel_bus.vvp

if [[ -f vendor/picorv32/picorv32.v && -f firmware/nexus32_smoke.hex ]]; then
  iverilog -g2012 -Wall -s tb_nexus32_soc \
    -o results/rtl/tb_nexus32_soc.vvp \
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
    tests/rtl/tb_nexus32_soc.sv
  vvp results/rtl/tb_nexus32_soc.vvp

  # Exercise the CPU-visible protected-read sentinel and rejected result write
  # while a real accelerator operation owns the memory banks.
  bash scripts/build_protected_access_firmware.sh
  iverilog -g2012 -Wall -s tb_nexus32_soc_protected_access \
    -o results/rtl/tb_nexus32_soc_protected_access.vvp \
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
    tests/rtl/tb_nexus32_soc_protected_access.sv
  vvp results/rtl/tb_nexus32_soc_protected_access.vvp

  # Exercise all three architectural choices through PicoRV32, the memory
  # bridge, the real accelerator CSR shell, BRAM prefetch, and result memory.
  bash scripts/build_multiarch_firmware.sh
  iverilog -g2012 -Wall -s tb_nexus32_soc_multiarch \
    -o results/rtl/tb_nexus32_soc_multiarch.vvp \
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
    tests/rtl/tb_nexus32_soc_multiarch.sv
  vvp results/rtl/tb_nexus32_soc_multiarch.vvp

  # Build a separate program that jumps to MMIO space and verify that an
  # instruction fetch never becomes an accelerator bus request.
  bash scripts/build_invalid_fetch_firmware.sh
  iverilog -g2012 -Wall -s tb_nexus32_invalid_fetch \
    -o results/rtl/tb_nexus32_invalid_fetch.vvp \
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
    tests/rtl/tb_nexus32_invalid_fetch.sv
  vvp results/rtl/tb_nexus32_invalid_fetch.vvp
else
  echo "SKIP: PicoRV32 SoC test requires vendor/picorv32/picorv32.v and firmware/nexus32_smoke.hex."
  echo "      Run scripts/vendor_picorv32.sh and scripts/build_smoke_firmware.sh first."
fi

# Backpressure/stability check: queue a second request while the first RAM read
# is outstanding; verify fields remain stable until ready and responses stay ordered.
iverilog -g2012 -Wall -s tb_nexus32_accel_bus_stall \
  -o results/rtl/tb_nexus32_accel_bus_stall.vvp \
  rtl/fir_q16_mac.sv \
  rtl/fir_q16_postprocess.sv \
  rtl/fir_seq_engine.sv \
  rtl/fir_parallel_engine.sv \
  rtl/fir_pipelined_engine.sv \
  rtl/fir_arch_selector.sv \
  rtl/fir_tap_bram.sv \
  rtl/fir_seq_accel.sv \
  rtl/nexus32_accel_bus.sv \
  tests/rtl/tb_nexus32_accel_bus_stall.sv
vvp results/rtl/tb_nexus32_accel_bus_stall.vvp

# Mid-operation reset recovery test uses the normal smoke firmware image.
if [[ -f vendor/picorv32/picorv32.v && -f firmware/nexus32_smoke.hex ]]; then
  iverilog -g2012 -Wall -s tb_nexus32_soc_reset_recovery \
    -o results/rtl/tb_nexus32_soc_reset_recovery.vvp \
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
    tests/rtl/tb_nexus32_soc_reset_recovery.sv
  vvp results/rtl/tb_nexus32_soc_reset_recovery.vvp
else
  echo "SKIP: reset recovery test requires PicoRV32 source and normal smoke firmware image."
fi
