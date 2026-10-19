#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

command -v tclsh >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: tclsh is required for the offline Basys-3 flow stub.' >&2
  exit 1
}

success_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-flow-success.XXXXXX")"
failure_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-flow-failure.XXXXXX")"
success_output="$success_root/output"
failure_output="$failure_root/output"

set +e
env -u STUB_FAIL_STAGE tclsh scripts/test_basys3_flow_stub.tcl "$success_output" 16 \
  >"$success_root/run.log" 2>&1
success_rc=$?
STUB_FAIL_STAGE=route_design tclsh scripts/test_basys3_flow_stub.tcl "$failure_output" 16 \
  >"$failure_root/run.log" 2>&1
failure_rc=$?
set -e

if [[ "$success_rc" -ne 0 ]]; then
  printf 'ERROR: all-success Basys-3 flow stub exited %s; log: %s\n' \
    "$success_rc" "$success_root/run.log" >&2
  exit 1
fi
if [[ ! -s "$success_output/build_summary.tsv" || ! -s "$success_output/build_summary.md" ]]; then
  printf '%s\n' 'ERROR: all-success Basys-3 flow stub did not create both summaries.' >&2
  exit 1
fi
if ! grep -Fq $'stage\twrite_bitstream\tPASS' "$success_output/build_summary.tsv"; then
  printf '%s\n' 'ERROR: all-success Basys-3 flow stub did not record bitstream PASS.' >&2
  exit 1
fi

if [[ "$failure_rc" -ne 1 ]]; then
  printf 'ERROR: injected route failure exited %s instead of 1; log: %s\n' \
    "$failure_rc" "$failure_root/run.log" >&2
  exit 1
fi
if ! grep -Fq $'stage\troute_design\tFAIL' "$failure_output/build_summary.tsv"; then
  printf '%s\n' 'ERROR: injected route failure was not recorded in the summary.' >&2
  exit 1
fi
if ! grep -Fq $'stage\twrite_bitstream\tSKIPPED' "$failure_output/build_summary.tsv"; then
  printf '%s\n' 'ERROR: stages after a mandatory failure were not skipped.' >&2
  exit 1
fi

printf 'PASS: Basys-3 Vivado flow stub success and failure propagation checks\n'
printf 'Success artifacts: %s\n' "$success_output"
printf 'Failure artifacts: %s\n' "$failure_output"
