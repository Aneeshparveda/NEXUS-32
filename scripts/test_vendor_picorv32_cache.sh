#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-vendor-cache-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ERROR: unexpected git invocation during vendor-cache regression: %s\n' "$*" >&2
exit 99
EOF
chmod +x "$fake_bin/git"

prepare_case() {
  local case_root="$1"
  mkdir -p "$case_root/scripts" "$case_root/vendor/picorv32"
  cp "$repo_root/scripts/vendor_picorv32.sh" "$case_root/scripts/vendor_picorv32.sh"
  chmod +x "$case_root/scripts/vendor_picorv32.sh"
  cp "$repo_root/vendor/picorv32/picorv32.v" "$case_root/vendor/picorv32/picorv32.v"
  cp "$repo_root/vendor/picorv32/COPYING" "$case_root/vendor/picorv32/COPYING"
  cp "$repo_root/vendor/picorv32/REVISION.txt" "$case_root/vendor/picorv32/REVISION.txt"
}

run_rejected_case() {
  local label="$1"
  local case_root="$2"
  local output

  if output="$(cd "$case_root" && PATH="$fake_bin:$PATH" bash scripts/vendor_picorv32.sh 2>&1)"; then
    printf 'ERROR: %s unexpectedly passed the vendor-cache fast path.\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  if ! grep -Fq 'Move it aside manually before re-vendoring' <<<"$output"; then
    printf 'ERROR: %s did not report the refuse-to-overwrite guidance.\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}

modified_case="$test_root/modified-source"
prepare_case "$modified_case"
printf '\nmodified\n' >>"$modified_case/vendor/picorv32/picorv32.v"
run_rejected_case 'modified picorv32.v with unchanged REVISION.txt marker' "$modified_case"

missing_copying_case="$test_root/missing-copying"
prepare_case "$missing_copying_case"
rm "$missing_copying_case/vendor/picorv32/COPYING"
run_rejected_case 'missing COPYING with correct source and REVISION.txt' "$missing_copying_case"

valid_case="$test_root/valid-cache"
prepare_case "$valid_case"
valid_output="$(cd "$valid_case" && PATH="$fake_bin:$PATH" bash scripts/vendor_picorv32.sh 2>&1)"
if ! grep -Fq 'already vendored at pinned revision' <<<"$valid_output"; then
  printf 'ERROR: correct pinned cache did not use the fast path.\n%s\n' "$valid_output" >&2
  exit 1
fi
printf 'PASS: correct pinned picorv32.v, COPYING, and REVISION.txt use the fast path\n'

printf 'PASS: PicoRV32 vendor-cache regression cases\n'
