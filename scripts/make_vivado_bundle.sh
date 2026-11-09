#!/usr/bin/env bash
# Build a self-contained zip for running the Vivado flows on a Windows host.
#
# The zip contains every tracked file from the working tree plus the two
# generated inputs a Windows Vivado host cannot produce itself (no bash, RISC-V
# toolchain, or network needed there):
#   vendor/picorv32/{picorv32.v,COPYING,REVISION.txt}  (pinned, verified)
#   firmware/nexus32_smoke.hex                         (freshly rebuilt)
# plus BUNDLE_COMMIT.txt for provenance, since the zip carries no .git.
# Batch files are converted to CRLF so cmd.exe labels work.
#
# Usage: bash scripts/make_vivado_bundle.sh [output_dir]   (default results/handoff)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-results/handoff}"
command -v zip >/dev/null 2>&1 || { echo "ERROR: zip is required" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f1
  else shasum -a 256 "$1" | cut -d ' ' -f1; fi
}

# Verify (or provision) the pinned CPU source and rebuild the firmware image
# from the current firmware/nexus32_smoke.S.
bash scripts/vendor_picorv32.sh
bash scripts/build_smoke_firmware.sh

commit="$(git rev-parse HEAD)"
short="$(git rev-parse --short HEAD)"
dirty=0
if [[ -n "$(git status --porcelain)" ]]; then
  dirty=1
  echo "WARNING: working tree has uncommitted changes; bundle is marked dirty." >&2
fi
suffix=""
[[ "$dirty" -eq 1 ]] && suffix="-dirty"

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-bundle.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
stage="$stage_root/nexus32"
mkdir -p "$stage"

# Tracked plus untracked-but-not-ignored files as they are in the working tree
# (deleted files are skipped). Ignored build products never enter the bundle.
while IFS= read -r -d '' path; do
  [[ -f "$path" ]] || continue
  mkdir -p "$stage/$(dirname "$path")"
  cp -p "$path" "$stage/$path"
done < <(git ls-files -z --cached --others --exclude-standard)

mkdir -p "$stage/vendor/picorv32" "$stage/firmware"
cp -p vendor/picorv32/picorv32.v vendor/picorv32/COPYING vendor/picorv32/REVISION.txt \
  "$stage/vendor/picorv32/"
cp -p firmware/nexus32_smoke.hex "$stage/firmware/nexus32_smoke.hex"

find "$stage" -name '*.bat' -print0 | while IFS= read -r -d '' bat; do
  perl -pi -e 's/\r?\n/\r\n/' "$bat"
done

cat >"$stage/BUNDLE_COMMIT.txt" <<EOF
commit=$commit
dirty=$dirty
created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
picorv32_sha256=$(sha256_file vendor/picorv32/picorv32.v)
firmware_sha256=$(sha256_file firmware/nexus32_smoke.hex)
EOF

mkdir -p "$OUT_DIR"
zip_path="$(cd "$OUT_DIR" && pwd)/nexus32-vivado-${short}${suffix}.zip"
rm -f "$zip_path"
(cd "$stage_root" && zip -qr "$zip_path" nexus32)

echo "Bundle: $zip_path"
echo "Contents: $(unzip -l "$zip_path" | tail -n 1 | awk '{print $2}') files, commit $short, dirty=$dirty"
echo "On Windows: unzip to a short path without spaces (e.g. C:\\nexus32), then follow docs/VIVADO_DAY.md."
