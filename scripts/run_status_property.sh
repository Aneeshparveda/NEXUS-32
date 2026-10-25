#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

RESULT_DIR="${NEXUS32_STAGE4B_RESULTS_DIR:-results/verification-closure/stage4b-20261024/status-property}"
mkdir -p "$RESULT_DIR"

if ! command -v iverilog >/dev/null 2>&1 || ! command -v vvp >/dev/null 2>&1; then
  printf 'NOT_RUN: STATUS property requires both iverilog and vvp\n' >&2
  exit 1
fi

ACCEL_SOURCES=(
  rtl/fir_q16_mac.sv
  rtl/fir_q16_postprocess.sv
  rtl/fir_seq_engine.sv
  rtl/fir_parallel_engine.sv
  rtl/fir_pipelined_engine.sv
  rtl/fir_arch_selector.sv
  rtl/fir_tap_bram.sv
  rtl/fir_seq_accel.sv
  rtl/nexus32_accel_bus.sv
  tests/rtl/tb_nexus32_accel_bus_status_property.sv
)

for lanes in 4 8 16 32; do
  vvp_path="$RESULT_DIR/tb_nexus32_accel_bus_status_property_l${lanes}.vvp"
  compile_log="$RESULT_DIR/status_property_l${lanes}.compile.log"
  run_log="$RESULT_DIR/status_property_l${lanes}.run.log"
  compile_command=(
    iverilog -g2012 -Wall
    -s tb_nexus32_accel_bus_status_property
    -P "tb_nexus32_accel_bus_status_property.LANES=${lanes}"
    -o "$vvp_path"
    "${ACCEL_SOURCES[@]}"
  )

  printf '\n--- STATUS property LANES=%s ---\n' "$lanes"
  printf '%q ' "${compile_command[@]}"
  printf '\n'
  if ! "${compile_command[@]}" > "$compile_log" 2>&1; then
    printf 'FAIL: STATUS property compile failed for LANES=%s; see %s\n' "$lanes" "$compile_log" >&2
    exit 1
  fi
  if ! vvp "$vvp_path" | tee "$run_log"; then
    printf 'FAIL: STATUS property simulation failed for LANES=%s; see %s\n' "$lanes" "$run_log" >&2
    exit 1
  fi
done

printf 'PASS: STATUS property regression passed for LANES=4,8,16,32\n'
printf 'Logs: %s\n' "$RESULT_DIR"
