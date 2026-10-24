#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

RESULT_DIR="${NEXUS32_STAGE4B_RESULTS_DIR:-results/verification-closure/stage4b-20261024/firmware-latency}"
mkdir -p "$RESULT_DIR"

if ! command -v iverilog >/dev/null 2>&1 || ! command -v vvp >/dev/null 2>&1; then
  printf 'NOT_RUN: firmware-latency measurement requires both iverilog and vvp\n' >&2
  exit 1
fi

bash scripts/build_smoke_firmware.sh | tee "$RESULT_DIR/build_smoke_firmware.log"

vvp_path="$RESULT_DIR/tb_nexus32_soc_latency_l32.vvp"
compile_log="$RESULT_DIR/firmware_latency_l32.compile.log"
run_log="$RESULT_DIR/firmware_latency_l32.run.log"

compile_command=(
  iverilog -g2012 -Wall
  -s tb_nexus32_soc_latency
  -P tb_nexus32_soc_latency.LANES=32
  -o "$vvp_path"
  vendor/picorv32/picorv32.v
  rtl/fir_q16_mac.sv
  rtl/fir_q16_postprocess.sv
  rtl/fir_seq_engine.sv
  rtl/fir_parallel_engine.sv
  rtl/fir_pipelined_engine.sv
  rtl/fir_arch_selector.sv
  rtl/fir_tap_bram.sv
  rtl/fir_seq_accel.sv
  rtl/nexus32_accel_bus.sv
  rtl/nexus32_soc.sv
  tests/rtl/tb_nexus32_soc_latency.sv
)

printf '%q ' "${compile_command[@]}"
printf '\n'
if ! "${compile_command[@]}" > "$compile_log" 2>&1; then
  printf 'FAIL: firmware-latency compile failed; see %s\n' "$compile_log" >&2
  exit 1
fi

if ! vvp "$vvp_path" | tee "$run_log"; then
  printf 'FAIL: firmware-latency simulation failed; see %s\n' "$run_log" >&2
  exit 1
fi

printf 'PASS: firmware-latency measurement completed at LANES=32\n'
printf 'Logs: %s\n' "$RESULT_DIR"
