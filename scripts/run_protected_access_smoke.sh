#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_LANES="${1:-all}"
bash scripts/build_protected_access_firmware.sh
mkdir -p results/rtl

run_lane() {
  local lanes="$1"
  echo "--- Testing CPU-driven protected access LANES=${lanes} ---"
  iverilog -g2012 -Wall -s tb_nexus32_soc_protected_access \
    -P tb_nexus32_soc_protected_access.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_soc_protected_access_l${lanes}.vvp" \
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
  vvp "results/rtl/tb_nexus32_soc_protected_access_l${lanes}.vvp"
  printf 'PASS: protected-access lane sweep LANES=%s\n' "$lanes"
}

if [[ "$TARGET_LANES" == "all" ]]; then
  # The existing protected-access firmware deliberately configures
  # TAP_COUNT=32.  A LANES<32 build therefore rejects the firmware's valid
  # start during preflight before ownership can be exercised.  Use the
  # explicitly recorded representative fallback rather than silently
  # presenting failed lower-lane preflight as ownership coverage.
  printf '%s\n' 'FALLBACK: representative LANES=32 protected-access route selected.'
  printf '%s\n' 'FALLBACK_REASON: existing tb_nexus32_soc_protected_access firmware uses TAP_COUNT=32; LANES<32 fails preflight before the ownership assertions. LANES=32 maximizes active-operation duration, while the bench checks ownership on the same accepted CPU edges.'
  run_lane 32
else
  run_lane "$TARGET_LANES"
fi
