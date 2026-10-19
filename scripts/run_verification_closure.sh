#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p results/verification-closure

OUT=results/verification-closure
LOG="$OUT/verification-closure.log"
COMMANDS="$OUT/commands.txt"
STATUS="$OUT/status.tsv"

: > "$LOG"
: > "$COMMANDS"
: > "$STATUS"
printf 'test\tstatus\tdetail\n' > "$STATUS"
exec > >(tee "$LOG") 2>&1

passed_tests=0
failed_tests=0
not_run_tests=0

record_status() {
  local name="$1"
  local status="$2"
  local detail="$3"

  printf '%s\t%s\t%s\n' "$name" "$status" "$detail" | tee -a "$STATUS"
  case "$status" in
    PASS) passed_tests=$((passed_tests + 1)) ;;
    NOT_RUN)
      not_run_tests=$((not_run_tests + 1))
      failed_tests=$((failed_tests + 1))
      ;;
    *) failed_tests=$((failed_tests + 1)) ;;
  esac
}

sources_available() {
  local source_path
  for source_path in "$@"; do
    if [[ ! -f "$source_path" ]]; then
      printf 'missing required source: %s\n' "$source_path"
      return 1
    fi
  done
}

run_iverilog_test() {
  local name="$1"
  local top="$2"
  local vvp_path="$3"
  local compile_log="$4"
  local run_log="$5"
  local parameter_arg="$6"
  shift 6
  local -a sources=("$@")
  local -a compile_command=(iverilog -g2012 -Wall -s "$top")
  local compile_rc
  local run_rc

  if [[ -n "$parameter_arg" ]]; then
    compile_command+=("$parameter_arg")
  fi
  compile_command+=(-o "$vvp_path" "${sources[@]}")

  printf '\n--- %s ---\n' "$name"
  printf '%q ' "${compile_command[@]}" | tee -a "$COMMANDS"
  printf '\n' | tee -a "$COMMANDS"
  printf '%q %q\n' vvp "$vvp_path" | tee -a "$COMMANDS"

  if ! sources_available "${sources[@]}"; then
    record_status "$name" NOT_RUN "required source is missing"
    return 0
  fi

  # Never execute a stale simulator binary after a failed or incomplete build.
  rm -f "$vvp_path"
  if "${compile_command[@]}" > "$compile_log" 2>&1; then
    :
  else
    compile_rc=$?
    record_status "$name" FAIL "compile failed (exit $compile_rc); see $compile_log"
    return 0
  fi

  if vvp "$vvp_path" | tee "$run_log"; then
    record_status "$name" PASS "simulation passed; see $run_log"
  else
    run_rc=$?
    record_status "$name" FAIL "simulation failed (exit $run_rc); see $run_log"
  fi
}

printf 'NEXUS-32 verification closure\n'
printf 'branch: '; git branch --show-current
printf 'source_revision: '; git rev-parse HEAD
printf 'date_utc: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
printf '\n'

printf '%s\n' '--- iverilog version ---'
iverilog -V 2>&1 || true
printf '%s\n' '--- vvp version ---'
vvp -V 2>&1 || true

ACCEL_SOURCES=(
  rtl/fir_q16_mac.sv
  rtl/fir_q16_postprocess.sv
  rtl/fir_seq_engine.sv
  rtl/fir_parallel_engine.sv
  rtl/fir_pipelined_engine.sv
  rtl/fir_arch_selector.sv
  rtl/fir_tap_bram.sv
  rtl/fir_seq_accel.sv
)

BUS_SOURCES=(
  "${ACCEL_SOURCES[@]}"
  rtl/nexus32_accel_bus.sv
)

BLOCK_SOURCES=(
  "${BUS_SOURCES[@]}"
  tests/rtl/tb_fir_seq_accel_block_1024.sv
)

PIPE_SOURCES=(
  rtl/fir_q16_postprocess.sv
  rtl/fir_pipelined_engine.sv
  tests/rtl/tb_fir_pipelined_latency.sv
)

REQUIRED_TESTS=(
  block_1024_l4
  block_1024_l8
  block_1024_l16
  block_1024_l32
  pipeline_latency_l4
  pipeline_latency_l8
  pipeline_latency_l16
  pipeline_latency_l32
  acceptance_block_processing_l4
  acceptance_block_processing_l8
  acceptance_block_processing_l16
  acceptance_block_processing_l32
  acceptance_block_config_l32
  acceptance_config_stage_l32
)

if ! command -v iverilog >/dev/null 2>&1 || ! command -v vvp >/dev/null 2>&1; then
  printf 'ERROR: required simulator tools are missing; iverilog and vvp are mandatory.\n'
  for test_name in "${REQUIRED_TESTS[@]}"; do
    record_status "$test_name" NOT_RUN "mandatory simulator prerequisite is missing"
  done
  printf 'FAIL: verification closure gate could not run because a mandatory simulator is missing.\n'
  printf 'Status report: %s\n' "$STATUS"
  exit 1
fi

run_block_1024() {
  local lanes="$1"
  run_iverilog_test \
    "block_1024_l${lanes}" \
    tb_fir_seq_accel_block_1024 \
    "$OUT/tb_fir_seq_accel_block_1024_l${lanes}.vvp" \
    "$OUT/block_1024_l${lanes}.compile.log" \
    "$OUT/block_1024_l${lanes}.run.log" \
    "-Ptb_fir_seq_accel_block_1024.LANES=${lanes}" \
    "${BLOCK_SOURCES[@]}"
}

run_pipeline_latency() {
  local lanes="$1"
  run_iverilog_test \
    "pipeline_latency_l${lanes}" \
    tb_fir_pipelined_latency \
    "$OUT/tb_fir_pipelined_latency_l${lanes}.vvp" \
    "$OUT/pipeline_latency_l${lanes}.compile.log" \
    "$OUT/pipeline_latency_l${lanes}.run.log" \
    "-Ptb_fir_pipelined_latency.LANES=${lanes}" \
    "${PIPE_SOURCES[@]}"
}

run_block_processing_acceptance() {
  local lanes="$1"
  run_iverilog_test \
    "acceptance_block_processing_l${lanes}" \
    tb_fir_seq_accel_block_processing \
    "$OUT/tb_fir_seq_accel_block_processing_l${lanes}.vvp" \
    "$OUT/block_processing_l${lanes}.compile.log" \
    "$OUT/block_processing_l${lanes}.run.log" \
    "-Ptb_fir_seq_accel_block_processing.LANES=${lanes}" \
    "${BUS_SOURCES[@]}" \
    tests/rtl/tb_fir_seq_accel_block_processing.sv
}

run_fixed_lane_acceptance() {
  local name="$1"
  local top="$2"
  local test_source="$3"
  run_iverilog_test \
    "$name" \
    "$top" \
    "$OUT/${name}.vvp" \
    "$OUT/${name}.compile.log" \
    "$OUT/${name}.run.log" \
    "" \
    "${ACCEL_SOURCES[@]}" \
    "$test_source"
}

for lanes in 4 8 16 32; do
  run_block_1024 "$lanes"
done

for lanes in 4 8 16 32; do
  run_pipeline_latency "$lanes"
done

for lanes in 4 8 16 32; do
  run_block_processing_acceptance "$lanes"
done

# These benches intentionally declare LANES=32 as a localparam and therefore
# have no compile-time lane sweep.  Run each once at its designed configuration.
run_fixed_lane_acceptance \
  acceptance_block_config_l32 \
  tb_fir_seq_accel_block_config \
  tests/rtl/tb_fir_seq_accel_block_config.sv
run_fixed_lane_acceptance \
  acceptance_config_stage_l32 \
  tb_fir_seq_accel_config_stage \
  tests/rtl/tb_fir_seq_accel_config_stage.sv

printf '\nVerification gate summary: PASS=%d FAIL=%d NOT_RUN=%d\n' \
  "$passed_tests" "$failed_tests" "$not_run_tests"
printf 'Status report: %s\n' "$STATUS"
printf 'Logs and commands: %s\n' "$OUT"
if (( failed_tests != 0 )); then
  printf 'FAIL: verification closure gate did not complete successfully.\n'
  exit 1
fi
printf 'PASS: verification closure gate completed successfully\n'
