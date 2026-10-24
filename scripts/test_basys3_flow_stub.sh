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

fixture_pinned_commit="ef203c2b0a3fb793280f5114941416c425c5b461"

prepare_vendor_fixture() {
  local case_root="$1"
  local vendor_state="$2"
  local fixture_root="$case_root/fixture"
  local source_rel

  mkdir -p "$fixture_root/vivado" "$fixture_root/scripts" \
    "$fixture_root/constraints" "$fixture_root/firmware" \
    "$fixture_root/rtl" "$fixture_root/vendor/picorv32"

  cp vivado/build_basys3.tcl "$fixture_root/vivado/build_basys3.tcl"
  cp scripts/test_basys3_flow_stub.tcl "$fixture_root/scripts/test_basys3_flow_stub.tcl"
  cp scripts/vendor_picorv32.sh "$fixture_root/scripts/vendor_picorv32_impl.sh"
  cp constraints/basys3.xdc "$fixture_root/constraints/basys3.xdc"

  cat >"$fixture_root/scripts/vendor_picorv32.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fixture_root="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' invoked >"$fixture_root/vendor_script_invoked.txt"
exec bash "$fixture_root/scripts/vendor_picorv32_impl.sh"
EOF
  chmod +x "$fixture_root/scripts/vendor_picorv32.sh"

  cat >"$fixture_root/scripts/build_smoke_firmware.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fixture_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$fixture_root/firmware"
printf '%s\n' stub-firmware >"$fixture_root/firmware/nexus32_smoke.hex"
EOF
  chmod +x "$fixture_root/scripts/build_smoke_firmware.sh"

  for source_rel in \
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
    rtl/top_basys3.sv; do
    : >"$fixture_root/$source_rel"
  done
  printf '%s\n' 'module picorv32; endmodule' >"$fixture_root/vendor/picorv32/picorv32.v"

  case "$vendor_state" in
    valid)
      cat >"$fixture_root/vendor/picorv32/REVISION.txt" <<EOF
Project: PicoRV32
Pinned commit: $fixture_pinned_commit
EOF
      ;;
    wrong)
      printf '%s\n' 'Pinned commit: wrong-revision' \
        >"$fixture_root/vendor/picorv32/REVISION.txt"
      ;;
    incomplete)
      rm -f "$fixture_root/vendor/picorv32/REVISION.txt"
      ;;
    *)
      printf 'ERROR: unknown vendor fixture state: %s\n' "$vendor_state" >&2
      return 2
      ;;
  esac

  git -C "$fixture_root" init -q
  git -C "$fixture_root" add .
  git -C "$fixture_root" \
    -c user.name='NEXUS-32 fixture' \
    -c user.email='nexus32-fixture@example.invalid' \
    commit -qm 'fixture'
}

vendor_valid_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-vendor-valid.XXXXXX")"
vendor_wrong_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-vendor-wrong.XXXXXX")"
vendor_incomplete_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-vendor-incomplete.XXXXXX")"
prepare_vendor_fixture "$vendor_valid_root" valid
prepare_vendor_fixture "$vendor_wrong_root" wrong
prepare_vendor_fixture "$vendor_incomplete_root" incomplete

set +e
env -u STUB_FAIL_STAGE tclsh scripts/test_basys3_flow_stub.tcl "$success_output" 16 \
  >"$success_root/run.log" 2>&1
success_rc=$?
STUB_FAIL_STAGE=route_design tclsh scripts/test_basys3_flow_stub.tcl "$failure_output" 16 \
  >"$failure_root/run.log" 2>&1
failure_rc=$?

env -u STUB_FAIL_STAGE tclsh \
  "$vendor_valid_root/fixture/scripts/test_basys3_flow_stub.tcl" \
  "$vendor_valid_root/output" 16 >"$vendor_valid_root/run.log" 2>&1
vendor_valid_rc=$?
env -u STUB_FAIL_STAGE tclsh \
  "$vendor_wrong_root/fixture/scripts/test_basys3_flow_stub.tcl" \
  "$vendor_wrong_root/output" 16 >"$vendor_wrong_root/run.log" 2>&1
vendor_wrong_rc=$?
env -u STUB_FAIL_STAGE tclsh \
  "$vendor_incomplete_root/fixture/scripts/test_basys3_flow_stub.tcl" \
  "$vendor_incomplete_root/output" 16 >"$vendor_incomplete_root/run.log" 2>&1
vendor_incomplete_rc=$?
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
for hierarchical_report in \
  "$success_output/reports/post_synth/utilization_hierarchical.rpt" \
  "$success_output/reports/post_implementation/utilization_hierarchical.rpt"; do
  if [[ ! -s "$hierarchical_report" ]]; then
    printf 'ERROR: successful flow did not create nonempty hierarchical report: %s\n' \
      "$hierarchical_report" >&2
    exit 1
  fi
done
if ! grep -Fq $'stage\tpost_synth.report_utilization_hierarchical\tPASS' "$success_output/build_summary.tsv" || \
   ! grep -Fq $'stage\tpost_impl.report_utilization_hierarchical\tPASS' "$success_output/build_summary.tsv"; then
  printf '%s\n' 'ERROR: successful flow did not record both hierarchical utilization stages.' >&2
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
if ! grep -Fq $'stage\tpost_impl.report_utilization_hierarchical\tSKIPPED' "$failure_output/build_summary.tsv"; then
  printf '%s\n' 'ERROR: route failure did not skip post-implementation hierarchical utilization.' >&2
  exit 1
fi

if [[ "$vendor_valid_rc" -ne 0 ]]; then
  printf 'ERROR: valid vendor fixture exited %s; log: %s\n' \
    "$vendor_valid_rc" "$vendor_valid_root/run.log" >&2
  exit 1
fi
if [[ ! -s "$vendor_valid_root/fixture/vendor_script_invoked.txt" ]]; then
  printf '%s\n' 'ERROR: board Tcl did not invoke the vendor script for an existing valid vendor tree.' >&2
  exit 1
fi
if ! grep -Fq $'stage\tvendor_rtl\tPASS' "$vendor_valid_root/output/build_summary.tsv" || \
   ! grep -Fq $'stage\twrite_bitstream\tPASS' "$vendor_valid_root/output/build_summary.tsv"; then
  printf '%s\n' 'ERROR: valid vendor fixture did not reach vendor and bitstream PASS stages.' >&2
  exit 1
fi

if [[ "$vendor_wrong_rc" -eq 0 ]]; then
  printf '%s\n' 'ERROR: incorrect vendor revision unexpectedly passed.' >&2
  exit 1
fi
if ! grep -Fq $'stage\tvendor_rtl\tFAIL' "$vendor_wrong_root/output/build_summary.tsv" || \
   grep -Fq $'stage\tsynthesis\tPASS' "$vendor_wrong_root/output/build_summary.tsv"; then
  printf '%s\n' 'ERROR: incorrect vendor revision did not stop synthesis.' >&2
  exit 1
fi
if ! grep -Fq 'different/unpinned PicoRV32 source' "$vendor_wrong_root/run.log"; then
  printf '%s\n' 'ERROR: incorrect vendor revision did not preserve vendor-script rejection behavior.' >&2
  exit 1
fi

if [[ "$vendor_incomplete_rc" -eq 0 ]]; then
  printf '%s\n' 'ERROR: incomplete vendor state unexpectedly passed.' >&2
  exit 1
fi
if ! grep -Fq $'stage\tvendor_rtl\tFAIL' "$vendor_incomplete_root/output/build_summary.tsv" || \
   grep -Fq $'stage\tsynthesis\tPASS' "$vendor_incomplete_root/output/build_summary.tsv"; then
  printf '%s\n' 'ERROR: incomplete vendor state did not stop synthesis.' >&2
  exit 1
fi
if ! grep -Fq 'different/unpinned PicoRV32 source' "$vendor_incomplete_root/run.log"; then
  printf '%s\n' 'ERROR: incomplete vendor state did not preserve vendor-script rejection behavior.' >&2
  exit 1
fi

printf 'PASS: Basys-3 Vivado flow stub success and failure propagation checks\n'
printf 'Success artifacts: %s\n' "$success_output"
printf 'Failure artifacts: %s\n' "$failure_output"
printf 'Vendor fixture artifacts: %s %s %s\n' \
  "$vendor_valid_root" "$vendor_wrong_root" "$vendor_incomplete_root"
