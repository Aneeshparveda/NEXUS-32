#!/usr/bin/env bash
# Offline test of the Windows-side evidence tools (no Vivado, no board):
#   vivado/program_board.tcl  build selection (dry run)
#   vivado/collect_evidence.tcl  EVIDENCE.md tables, UART verdict, copies
set -euo pipefail
cd "$(dirname "$0")/.."
command -v tclsh >/dev/null 2>&1 || { echo "ERROR: tclsh is required" >&2; exit 1; }

root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-evidence-tools.XXXXXX")"
mkdir -p "$root/vivado" "$root/results/vivado" "$root/results/evidence" "$root/results/vivado_core"
cp vivado/program_board.tcl vivado/collect_evidence.tcl "$root/vivado/"
printf 'commit=0123abc\ndirty=0\ncreated_utc=2026-11-10T00:00:00Z\n' >"$root/BUNDLE_COMMIT.txt"

make_build() {
  local name="$1" status="$2" lanes="$3" mhz="$4" timing="$5" wns="$6" imem="$7"
  local dir="$root/results/vivado/$name"
  mkdir -p "$dir/reports/post_implementation"
  {
    printf 'BUILD_STATUS=%s\nLANES=%s\nSYS_CLK_MHZ=%s\nFIRMWARE=demo\n' "$status" "$lanes" "$mhz"
    printf 'TIMING_MET=%s\nWNS_NS=%s\nTNS_NS=0.000\nWHS_NS=0.050\nTHS_NS=0.000\n' "$timing" "$wns"
    printf 'LUT=4000\nFF=3000\nDSP=68\nBRAM_TILES=11\nIMEM_INIT_CHECK=%s\n' "$imem"
    printf 'VIVADO_VERSION=v2024.2\nBITSTREAM_SHA256=%s\n' "sha-$name"
  } >"$dir/metrics.txt"
  printf 'stub bitstream\n' >"$dir/top_basys3.bit"
  printf 'stub utilization\n' >"$dir/reports/post_implementation/utilization.rpt"
  printf 'stub summary\n' >"$dir/build_summary.md"
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
program() {
  NEXUS32_PROGRAM_DRY_RUN=1 tclsh "$root/vivado/program_board.tcl" "$@" >"$root/program.log" 2>&1
}
selected() { sed -n 's/^BUILD=//p' "$root/results/evidence/programmed_build.txt"; }

# 1. No builds at all: programming must refuse.
if program; then fail "program_board accepted an empty results tree"; fi
grep -Fq 'no programmable build found' "$root/program.log" || fail "missing no-build message"

# 2. Preference: L8@100 failed timing, L8@50 met it -> L8@50 wins over L4.
make_build basys3_l4 PASS 4 100 YES 0.400 PASS
make_build basys3_l8 PASS 8 100 NO -1.234 PASS
make_build basys3_l8_50mhz PASS 8 50 YES 6.100 PASS
program || fail "program_board dry run failed: $(cat "$root/program.log")"
[[ "$(selected)" == "basys3_l8_50mhz" ]] || fail "expected basys3_l8_50mhz, got $(selected)"

# 3. A build with a failed IMEM check is never chosen.
make_build basys3_l8_50mhz PASS 8 50 YES 6.100 FAIL
program || fail "program_board dry run failed"
[[ "$(selected)" == "basys3_l4" ]] || fail "expected basys3_l4 after IMEM failure, got $(selected)"

# 4. Nothing met timing: fall back to the first passing build, with a warning.
make_build basys3_l4 PASS 4 100 NO -0.100 PASS
program || fail "program_board dry run failed"
[[ "$(selected)" == "basys3_l8" ]] || fail "expected basys3_l8 fallback, got $(selected)"
grep -Fq 'no build met timing' "$root/results/evidence/programmed_build.txt" || fail "missing timing warning"

# 5. Explicit build name is honoured; an unknown one is rejected.
program basys3_l4 || fail "explicit build rejected"
[[ "$(selected)" == "basys3_l4" ]] || fail "explicit build not used"
if program basys3_l99; then fail "unknown explicit build accepted"; fi

# 6. Collector: tables, UART verdict and copies.
printf '\r\n=== NEXUS-32 board demo (PicoRV32 + 3 FIR engines) ===\r\narch=SEQ     check=PASS\r\nNEXUS32 RESULT: PASS\r\n\r\n=== NEXUS-32 bo' \
  >"$root/results/evidence/uart_log.txt"
cat >"$root/results/vivado_core/characterization_summary.csv" <<'CSV'
"Case","Top","LANES","Status","Report_Directory","Command","Failure_Stage","Failure_Message","LUTs","FFs","DSPs","BRAMs","WNS_ns","Timing_Met","Data_Path_Delay_ns","Source_Commit","Source_Dirty"
"parallel_l8","fir_parallel_engine","8","PASS","r","synth_design -generic ""LANES=8""","N/A","N/A","900","300","32","0","-3.100","NO","12.900","UNKNOWN","UNKNOWN"
CSV
printf 'NEXUS-32 RUN_ALL started\n' >"$root/results/run_all_log.txt"
tclsh "$root/vivado/collect_evidence.tcl" >"$root/collect.log" 2>&1 || fail "collector failed: $(cat "$root/collect.log")"
evidence="$root/results/evidence/EVIDENCE.md"
for expected in \
  '| basys3_l8 | PASS | 8 | 100 | demo | NO | -1.234 |' \
  '| basys3_l8_50mhz | PASS | 8 | 50 | demo | YES | 6.100 |' \
  '| parallel_l8 | fir_parallel_engine | 8 | PASS | 900 | 300 | 32 | 0 | -3.100 | NO |' \
  'Board verdict: PASS' \
  '| Source commit | 0123abc |' \
  'NEXUS32 RESULT: PASS'; do
  grep -Fq -- "$expected" "$evidence" || fail "EVIDENCE.md is missing: $expected"
done
[[ "$(grep -c 'NEXUS-32 board demo' "$evidence")" -eq 1 ]] || fail "EVIDENCE.md should hold exactly one UART report block"
grep -Fxq '=== NEXUS-32 bo' "$evidence" && fail "EVIDENCE.md included a truncated UART block"
for copied in board/basys3_l8/metrics.txt board/basys3_l8/build_summary.md \
              board/basys3_l8/reports/post_implementation/utilization.rpt \
              core/characterization_summary.csv run_all_log.txt; do
  [[ -s "$root/results/evidence/$copied" ]] || fail "collector did not copy $copied"
done
find "$root/results/evidence" -name '*.bit' | grep -q . && fail "collector copied a bitstream"

printf 'PASS: evidence tools (board selection: preference, IMEM gate, timing fallback, explicit/unknown build; collector: board/core tables, UART verdict, copies, no bitstreams)\n'
