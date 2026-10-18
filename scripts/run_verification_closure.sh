#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p results/verification-closure

OUT=results/verification-closure
LOG="$OUT/verification-closure.log"
COMMANDS="$OUT/commands.txt"

: > "$LOG"
: > "$COMMANDS"
exec > >(tee "$LOG") 2>&1

printf 'NEXUS-32 verification closure\n'
printf 'branch: '; git branch --show-current
printf 'source_revision: '; git rev-parse HEAD
printf 'date_utc: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
printf '\n'

printf '%s\n' '--- iverilog version ---'
iverilog -V 2>&1 || true
printf '%s\n' '--- vvp version ---'
vvp -V 2>&1 || true

BLOCK_SOURCES=(
  rtl/fir_q16_mac.sv
  rtl/fir_q16_postprocess.sv
  rtl/fir_seq_engine.sv
  rtl/fir_parallel_engine.sv
  rtl/fir_pipelined_engine.sv
  rtl/fir_arch_selector.sv
  rtl/fir_tap_bram.sv
  rtl/fir_seq_accel.sv
  rtl/nexus32_accel_bus.sv
  tests/rtl/tb_fir_seq_accel_block_1024.sv
)

PIPE_SOURCES=(
  rtl/fir_q16_postprocess.sv
  rtl/fir_pipelined_engine.sv
  tests/rtl/tb_fir_pipelined_latency.sv
)

run_block_1024() {
  local lanes="$1"
  local vvp_path="$OUT/tb_fir_seq_accel_block_1024_l${lanes}.vvp"
  local compile_log="$OUT/block_1024_l${lanes}.compile.log"
  local run_log="$OUT/block_1024_l${lanes}.run.log"
  local command="iverilog -g2012 -Wall -s tb_fir_seq_accel_block_1024 -Ptb_fir_seq_accel_block_1024.LANES=${lanes} -o ${vvp_path} ${BLOCK_SOURCES[*]}"

  printf '\n--- Full 1024-sample block and timing scoreboard LANES=%s ---\n' "$lanes"
  printf '%s\n' "$command" | tee -a "$COMMANDS"
  iverilog -g2012 -Wall \
    -s tb_fir_seq_accel_block_1024 \
    -Ptb_fir_seq_accel_block_1024.LANES="${lanes}" \
    -o "$vvp_path" \
    "${BLOCK_SOURCES[@]}" > "$compile_log" 2>&1
  vvp "$vvp_path" | tee "$run_log"
}

run_pipeline_latency() {
  local lanes="$1"
  local vvp_path="$OUT/tb_fir_pipelined_latency_l${lanes}.vvp"
  local compile_log="$OUT/pipeline_latency_l${lanes}.compile.log"
  local run_log="$OUT/pipeline_latency_l${lanes}.run.log"
  local command="iverilog -g2012 -Wall -s tb_fir_pipelined_latency -Ptb_fir_pipelined_latency.LANES=${lanes} -o ${vvp_path} ${PIPE_SOURCES[*]}"

  printf '\n--- Direct pipelined latency experiment LANES=%s ---\n' "$lanes"
  printf '%s\n' "$command" | tee -a "$COMMANDS"
  iverilog -g2012 -Wall \
    -s tb_fir_pipelined_latency \
    -Ptb_fir_pipelined_latency.LANES="${lanes}" \
    -o "$vvp_path" \
    "${PIPE_SOURCES[@]}" > "$compile_log" 2>&1
  vvp "$vvp_path" | tee "$run_log"
}

for lanes in 4 8 16 32; do
  run_block_1024 "$lanes"
done

for lanes in 4 8 16 32; do
  run_pipeline_latency "$lanes"
done

printf '\nPASS: verification closure experiments completed\n'
printf 'Logs and commands: %s\n' "$OUT"
