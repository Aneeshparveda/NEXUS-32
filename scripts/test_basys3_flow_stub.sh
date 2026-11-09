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

  local firmware_name
  for firmware_name in smoke demo; do
    cat >"$fixture_root/scripts/build_${firmware_name}_firmware.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
fixture_root="\$(cd "\$(dirname "\$0")/.." && pwd)"
mkdir -p "\$fixture_root/firmware"
printf '%s\\n' stub-firmware >"\$fixture_root/firmware/nexus32_${firmware_name}.hex"
EOF
    chmod +x "$fixture_root/scripts/build_${firmware_name}_firmware.sh"
  done

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
    rtl/nexus32_uart_tx.sv rtl/nexus32_soc.sv \
    rtl/top_basys3.sv; do
    : >"$fixture_root/$source_rel"
  done
  cp vendor/picorv32/picorv32.v "$fixture_root/vendor/picorv32/picorv32.v"
  cp vendor/picorv32/COPYING "$fixture_root/vendor/picorv32/COPYING"

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

# Prebuilt-input (Windows handoff bundle) mode: no bash scripts, toolchain, or
# git may be used.  The fixture drops .git and records BUNDLE_COMMIT.txt.
prepare_prebuilt_fixture() {
  local case_root="$1"
  local vendor_state="$2"
  local firmware_state="$3"
  prepare_vendor_fixture "$case_root" "$vendor_state"
  local fixture_root="$case_root/fixture"
  # Rename instead of rm -rf: a background git process may still be writing.
  mv "$fixture_root/.git" "$case_root/fixture-git-removed"
  printf 'commit=%s\ndirty=0\n' 0123456789abcdef0123456789abcdef01234567 \
    >"$fixture_root/BUNDLE_COMMIT.txt"
  case "$firmware_state" in
    valid) cp firmware/nexus32_smoke.hex firmware/nexus32_demo.hex "$fixture_root/firmware/" ;;
    corrupt)
      cp firmware/nexus32_smoke.hex "$fixture_root/firmware/nexus32_smoke.hex"
      printf '%s\n' stub-firmware >"$fixture_root/firmware/nexus32_demo.hex"
      ;;
  esac
}

run_prebuilt_case() {
  local case_root="$1"
  set +e
  NEXUS32_INPUTS=prebuilt env -u STUB_FAIL_STAGE tclsh \
    "$case_root/fixture/scripts/test_basys3_flow_stub.tcl" \
    "$case_root/output" 8 >"$case_root/run.log" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

prebuilt_valid_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-prebuilt-valid.XXXXXX")"
prebuilt_wrong_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-prebuilt-wrong.XXXXXX")"
prebuilt_corrupt_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-prebuilt-corrupt.XXXXXX")"
prepare_prebuilt_fixture "$prebuilt_valid_root" valid valid
prepare_prebuilt_fixture "$prebuilt_wrong_root" wrong valid
prepare_prebuilt_fixture "$prebuilt_corrupt_root" valid corrupt

prebuilt_valid_rc=0
run_prebuilt_case "$prebuilt_valid_root" || prebuilt_valid_rc=$?
prebuilt_wrong_rc=0
run_prebuilt_case "$prebuilt_wrong_root" || prebuilt_wrong_rc=$?
prebuilt_corrupt_rc=0
run_prebuilt_case "$prebuilt_corrupt_root" || prebuilt_corrupt_rc=$?

prebuilt_summary="$prebuilt_valid_root/output/build_summary.tsv"
if [[ "$prebuilt_valid_rc" -ne 0 ]] || \
   ! grep -Fq $'stage\ttoolchain_selection\tSKIPPED' "$prebuilt_summary" || \
   ! grep -Fq $'stage\tvendor_rtl\tPASS' "$prebuilt_summary" || \
   ! grep -Fq $'stage\tsmoke_firmware\tPASS' "$prebuilt_summary" || \
   ! grep -Fq $'stage\twrite_bitstream\tPASS' "$prebuilt_summary" || \
   ! grep -Fq '0123456789abcdef0123456789abcdef01234567 (from BUNDLE_COMMIT.txt)' "$prebuilt_summary" || \
   ! grep -Fq $'metadata\tlanes\tPASS\t\t8' "$prebuilt_summary"; then
  printf 'ERROR: valid prebuilt bundle did not build cleanly (rc=%s); log: %s\n' \
    "$prebuilt_valid_rc" "$prebuilt_valid_root/run.log" >&2
  exit 1
fi
if [[ -e "$prebuilt_valid_root/fixture/vendor_script_invoked.txt" ]]; then
  printf '%s\n' 'ERROR: prebuilt mode invoked the bash vendor script.' >&2
  exit 1
fi
if ! cmp -s firmware/nexus32_demo.hex "$prebuilt_valid_root/output/firmware/nexus32_demo.hex"; then
  printf '%s\n' 'ERROR: prebuilt mode did not stage the firmware working copy.' >&2
  exit 1
fi

for bad_case in "$prebuilt_wrong_root:$prebuilt_wrong_rc:different/unpinned PicoRV32 source" \
                "$prebuilt_corrupt_root:$prebuilt_corrupt_rc:expected 4096"; do
  bad_root="${bad_case%%:*}"
  bad_rest="${bad_case#*:}"
  bad_rc="${bad_rest%%:*}"
  bad_text="${bad_rest#*:}"
  if [[ "$bad_rc" -eq 0 ]] || \
     ! grep -Fq $'stage\tvendor_rtl\tFAIL' "$bad_root/output/build_summary.tsv" || \
     grep -Fq $'stage\tsynthesis\tPASS' "$bad_root/output/build_summary.tsv" || \
     ! grep -Fq "$bad_text" "$bad_root/run.log"; then
    printf 'ERROR: invalid prebuilt bundle was not rejected before synthesis; log: %s\n' \
      "$bad_root/run.log" >&2
    exit 1
  fi
done

# SoC clock argument and post-synthesis IMEM guard, on a valid prebuilt bundle.
guard_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-basys3-guard.XXXXXX")"
prepare_prebuilt_fixture "$guard_root" valid valid
guard_tcl="$guard_root/fixture/scripts/test_basys3_flow_stub.tcl"

run_guard_case() {
  local name="$1" imem_state="$2"
  shift 2
  set +e
  if [[ -n "$imem_state" ]]; then
    NEXUS32_INPUTS=prebuilt STUB_IMEM_BRAMS="$imem_state" env -u STUB_FAIL_STAGE \
      tclsh "$guard_tcl" "$guard_root/$name" "$@" >"$guard_root/$name.log" 2>&1
  else
    NEXUS32_INPUTS=prebuilt env -u STUB_FAIL_STAGE -u STUB_IMEM_BRAMS \
      tclsh "$guard_tcl" "$guard_root/$name" "$@" >"$guard_root/$name.log" 2>&1
  fi
  local rc=$?
  set -e
  printf '%s' "$rc"
}

clk50_rc="$(run_guard_case clk50 loaded 8 50)"
if [[ "$clk50_rc" -ne 0 ]] || \
   ! grep -Fq $'metadata\tsys_clk_mhz\tPASS\t\t50' "$guard_root/clk50/build_summary.tsv" || \
   ! grep -Fq 'SYS_CLK_MHZ=50' "$guard_root/clk50/build_summary.tsv" || \
   ! grep -Fq $'stage\tpost_synth.imem_init_check\tPASS' "$guard_root/clk50/build_summary.tsv" || \
   ! grep -Fq 'IMEM init check: 2 of 2 IMEM block RAMs carry firmware data' "$guard_root/clk50.log"; then
  printf 'ERROR: 50 MHz build with loaded IMEM did not pass; log: %s\n' "$guard_root/clk50.log" >&2
  exit 1
fi

clk_bad_rc="$(run_guard_case clk75 loaded 8 75)"
if [[ "$clk_bad_rc" -ne 2 ]] || ! grep -Fq 'SYS_CLK_MHZ must be one of 100, 50, or 25' "$guard_root/clk75.log"; then
  printf 'ERROR: unsupported 75 MHz clock was not rejected; log: %s\n' "$guard_root/clk75.log" >&2
  exit 1
fi

for imem_state in none zero; do
  imem_rc="$(run_guard_case "imem_$imem_state" "$imem_state" 8)"
  if [[ "$imem_rc" -eq 0 ]] || \
     ! grep -Fq $'stage\tpost_synth.imem_init_check\tFAIL' "$guard_root/imem_$imem_state/build_summary.tsv" || \
     ! grep -Fq $'stage\twrite_bitstream\tSKIPPED' "$guard_root/imem_$imem_state/build_summary.tsv"; then
    printf 'ERROR: IMEM guard did not stop the flow for state %s; log: %s\n' \
      "$imem_state" "$guard_root/imem_$imem_state.log" >&2
    exit 1
  fi
done

override_rc="$(NEXUS32_SKIP_IMEM_CHECK=1 run_guard_case imem_override none 8)"
if [[ "$override_rc" -ne 0 ]] || ! grep -Fq 'overridden by NEXUS32_SKIP_IMEM_CHECK=1' "$guard_root/imem_override.log"; then
  printf 'ERROR: NEXUS32_SKIP_IMEM_CHECK=1 did not override the IMEM guard; log: %s\n' \
    "$guard_root/imem_override.log" >&2
  exit 1
fi

# Key metrics: parsed from report-shaped stub output into the summaries and
# metrics.txt; a negative WNS must yield TIMING_MET=NO (drives the 50 MHz retry).
metrics_file="$guard_root/clk50/metrics.txt"
for expected in 'BUILD_STATUS=PASS' 'TIMING_MET=YES' 'WNS_NS=0.512' 'WHS_NS=0.045' 'TNS_NS=-1.000' \
                'LUT=4321' 'FF=3210' 'DSP=68' 'BRAM_TILES=11' 'IMEM_INIT_CHECK=PASS' \
                'SYS_CLK_MHZ=50' 'FIRMWARE=demo' 'METRICS_SOURCE=post_implementation'; do
  if ! grep -Fxq "$expected" "$metrics_file"; then
    printf 'ERROR: metrics.txt is missing %s; file: %s\n' "$expected" "$metrics_file" >&2
    exit 1
  fi
done
if ! grep -Fq '| DSP | 68 |' "$guard_root/clk50/build_summary.md"; then
  printf 'ERROR: build_summary.md lacks the key-metrics table\n' >&2
  exit 1
fi
set +e
NEXUS32_INPUTS=prebuilt STUB_IMEM_BRAMS=loaded STUB_WNS=-2.345 env -u STUB_FAIL_STAGE \
  tclsh "$guard_tcl" "$guard_root/negative_wns" 8 >"$guard_root/negative_wns.log" 2>&1
negative_rc=$?
NEXUS32_INPUTS=prebuilt NEXUS32_FIRMWARE=smoke STUB_IMEM_BRAMS=loaded env -u STUB_FAIL_STAGE \
  tclsh "$guard_tcl" "$guard_root/smoke_fw" 4 >"$guard_root/smoke_fw.log" 2>&1
smoke_rc=$?
NEXUS32_INPUTS=prebuilt NEXUS32_FIRMWARE=bogus env -u STUB_FAIL_STAGE \
  tclsh "$guard_tcl" "$guard_root/bogus_fw" 4 >"$guard_root/bogus_fw.log" 2>&1
bogus_rc=$?
set -e
if [[ "$negative_rc" -ne 0 ]] || ! grep -Fxq 'TIMING_MET=NO' "$guard_root/negative_wns/metrics.txt" || \
   ! grep -Fxq 'WNS_NS=-2.345' "$guard_root/negative_wns/metrics.txt"; then
  printf 'ERROR: negative WNS was not reported as TIMING_MET=NO; log: %s\n' "$guard_root/negative_wns.log" >&2
  exit 1
fi
if [[ "$smoke_rc" -ne 0 ]] || ! grep -Fxq 'FIRMWARE=smoke' "$guard_root/smoke_fw/metrics.txt" || \
   ! cmp -s firmware/nexus32_smoke.hex "$guard_root/smoke_fw/firmware/nexus32_demo.hex"; then
  printf 'ERROR: NEXUS32_FIRMWARE=smoke did not select and stage the smoke image; log: %s\n' \
    "$guard_root/smoke_fw.log" >&2
  exit 1
fi
if [[ "$bogus_rc" -ne 2 ]] || ! grep -Fq "NEXUS32_FIRMWARE must be 'demo' or 'smoke'" "$guard_root/bogus_fw.log"; then
  printf 'ERROR: an unknown NEXUS32_FIRMWARE was not rejected; log: %s\n' "$guard_root/bogus_fw.log" >&2
  exit 1
fi

printf 'PASS: Basys-3 Vivado flow stub success and failure propagation checks\n'
printf 'PASS: prebuilt-input (Windows bundle) mode accepted a valid bundle and rejected wrong-pin and corrupt-firmware bundles\n'
printf 'PASS: key metrics parsed into build_summary and metrics.txt; negative WNS -> TIMING_MET=NO; firmware selection demo/smoke/invalid\n'
printf 'PASS: SYS_CLK_MHZ argument (50 accepted, 75 rejected) and IMEM guard (none/zero fail, loaded pass, override honored)\n'
printf 'Success artifacts: %s\n' "$success_output"
printf 'Failure artifacts: %s\n' "$failure_output"
printf 'Vendor fixture artifacts: %s %s %s\n' \
  "$vendor_valid_root" "$vendor_wrong_root" "$vendor_incomplete_root"
