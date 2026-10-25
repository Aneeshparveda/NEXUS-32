#!/usr/bin/env bash
# T3-2 full-1024 runner (Mac-run clone only, accepted by name 2026-10-25).
# Clean behaviour is unchanged apart from: generate the expected vector
# before simulating, gate on its case-A SHA, and pass +expected_file /
# +expected_sha to vvp. Negative modes are new, in this file only
# (no new runner file, no Makefile/CI change, per T3-2 section 6).
#
# Usage:
#   bash scripts/run_soc_block_1024.sh all        # clean, LANES 4/8/16/32
#   bash scripts/run_soc_block_1024.sh 32         # clean, one lane
#   bash scripts/run_soc_block_1024.sh neg-n1 [lane]   # corrupt 512, default lane 32
#   bash scripts/run_soc_block_1024.sh neg-n2 [lane]   # corrupt 0
#   bash scripts/run_soc_block_1024.sh neg-n3 [lane]   # wrong expected count
#   bash scripts/run_soc_block_1024.sh neg-n4a [lane]  # missing expected file
#   bash scripts/run_soc_block_1024.sh neg-n4b [lane]  # truncated (1023-line) file
#
# A negative mode's suite-PASS condition is INVERTED: the vvp run must
# exit non-zero, its log must contain the exact fatal string, and (for
# N1/N2) the prior clean FULL_CHECK line, and must contain no PASS line.
# A negative that exits 0 is a FAIL of the negative test, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."

CASE_A_SHA="6a0dcde7a927d0d181c931f8df773510c0078e4f18d965c1ee6e82da752c0a16"
EXPECTED_FILE="build/block_1024_expected.mem"
TRUNC_FILE="build/block_1024_expected_trunc1023.mem"
TARGET="${1:-all}"
MODE="clean"
LANES_ARG=""

case "$TARGET" in
  neg-n1|neg-n2|neg-n3|neg-n4a|neg-n4b)
    MODE="$TARGET"
    LANES_ARG="${2:-32}"
    ;;
  all|4|8|16|32)
    MODE="clean"
    LANES_ARG="$TARGET"
    ;;
  *)
    echo "Usage: $0 {all|4|8|16|32|neg-n1|neg-n2|neg-n3|neg-n4a|neg-n4b} [lane]" >&2
    exit 2
    ;;
esac

bash scripts/build_block_1024_firmware.sh
mkdir -p results/rtl

# Generate the default-path expected file on every invocation, and gate
# on the case-A SHA before any simulation (T3-2 section 5, step 2).
# Only the default path is deleted/regenerated; an explicitly supplied
# expected file (the N4b truncated file) is never overwritten (R2-6,
# distinct-path formulation).
generate_expected() {
  rm -f "$EXPECTED_FILE"
  local gen_output gen_sha
  gen_output="$(python3 scripts/gen_soc_block_1024_expected.py "$EXPECTED_FILE")"
  echo "$gen_output"
  gen_sha="$(printf '%s\n' "$gen_output" | grep -o 'sha256=[0-9a-f]*' | cut -d= -f2 || true)"
  if [[ "$gen_sha" != "$CASE_A_SHA" ]]; then
    echo "ERROR: generator SHA $gen_sha != case-A SHA $CASE_A_SHA; stopping before simulation" >&2
    exit 1
  fi
}

compile_lane() {
  local lanes="$1" out="$2"
  iverilog -g2012 -Wall -s tb_nexus32_soc_block_1024 \
    -P tb_nexus32_soc_block_1024.LANES="${lanes}" \
    -o "$out" \
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
    tests/rtl/tb_nexus32_soc_block_1024.sv
}

run_lane() {
  local lanes="$1"
  echo "--- Testing CPU-driven 1024-sample block LANES=${lanes} ---"
  compile_lane "$lanes" "results/rtl/tb_nexus32_soc_block_1024_l${lanes}.vvp"
  vvp "results/rtl/tb_nexus32_soc_block_1024_l${lanes}.vvp" \
    "+expected_file=${EXPECTED_FILE}" "+expected_sha=${CASE_A_SHA}"
}

# Negative runner: one vvp invocation, inverted pass condition.
run_negative() {
  local mode="$1" lanes="$2"
  local vvp_file="results/rtl/tb_nexus32_soc_block_1024_neg_${mode}_l${lanes}.vvp"
  local log="results/rtl/tb_nexus32_soc_block_1024_neg_${mode}_l${lanes}.log"
  local expected_file_arg="$EXPECTED_FILE"
  local extra_plusarg=""
  local want_fatal=""

  case "$mode" in
    neg-n1)
      extra_plusarg="+neg_corrupt_index=512"
      want_fatal="FULL_RESULT_MISMATCH index=512 expected=00010000 actual=00010001"
      ;;
    neg-n2)
      extra_plusarg="+neg_corrupt_index=0"
      want_fatal="FULL_RESULT_MISMATCH index=0 expected=00008000 actual=00008001"
      ;;
    neg-n3)
      extra_plusarg="+neg_expected_count=1023"
      want_fatal="NEGATIVE_COUNT_MISMATCH observed=1024 expected=1023"
      ;;
    neg-n4a)
      expected_file_arg="/nonexistent/block_1024_expected.mem"
      want_fatal="EXPECTED_FILE_MISSING"
      ;;
    neg-n4b)
      head -n 1023 "$EXPECTED_FILE" > "$TRUNC_FILE"
      expected_file_arg="$TRUNC_FILE"
      want_fatal="EXPECTED_FILE_SHORT"
      ;;
  esac

  echo "--- Negative $mode LANES=${lanes} (expect non-zero exit, fatal: $want_fatal) ---"
  compile_lane "$lanes" "$vvp_file"
  local status=0
  set +e
  # extra_plusarg is a single plusarg or empty; unquoted on purpose so
  # an empty value passes no argument (macOS bash 3.2 + set -u safe).
  vvp "$vvp_file" "+expected_file=${expected_file_arg}" "+expected_sha=${CASE_A_SHA}" $extra_plusarg > "$log" 2>&1
  status=$?
  set -e
  echo "negative log: $log (vvp exit $status)"
  local ok=1
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: negative $mode exited 0 (checker did not fail as designed)" >&2
    ok=0
  fi
  if ! grep -qF "$want_fatal" "$log"; then
    echo "FAIL: negative $mode log lacks exact fatal string: $want_fatal" >&2
    ok=0
  fi
  if grep -q "PASS: CPU-driven" "$log"; then
    echo "FAIL: negative $mode log contains a PASS line" >&2
    ok=0
  fi
  # N1/N2 only: the clean FULL_CHECK line must precede the corruption fatal.
  if [[ "$mode" == "neg-n1" || "$mode" == "neg-n2" ]]; then
    if ! grep -q "SOC_BLOCK_1024_FULL_CHECK" "$log"; then
      echo "FAIL: negative $mode log lacks the prior clean FULL_CHECK line" >&2
      ok=0
    fi
  fi
  if [[ "$ok" -eq 1 ]]; then
    echo "PASS: negative $mode behaved as designed (non-zero exit, exact fatal, no PASS line)"
  else
    echo "FAIL: negative $mode did not behave as designed; see $log" >&2
    exit 1
  fi
}

generate_expected

if [[ "$MODE" == "clean" ]]; then
  if [[ "$LANES_ARG" == "all" ]]; then
    for lanes in 4 8 16 32; do
      run_lane "$lanes"
    done
  else
    run_lane "$LANES_ARG"
  fi
else
  run_negative "$MODE" "$LANES_ARG"
fi
