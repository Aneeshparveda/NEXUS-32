#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_URL="https://github.com/YosysHQ/picorv32.git"
PINNED_COMMIT="ef203c2b0a3fb793280f5114941416c425c5b461"
# SHA-256 of picorv32.v obtained from the checkout at PINNED_COMMIT.
PINNED_SOURCE_SHA256="0836050971b3c6cdd28ac3b1e5719a67fb645161912bef1e472e63995ceb0622"
DEST="vendor/picorv32"

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | cut -d ' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | cut -d ' ' -f1
  else
    echo "ERROR: neither sha256sum nor shasum is available to verify $file." >&2
    return 1
  fi
}

cache_reason="required cache files are missing"
if [[ -f "$DEST/picorv32.v" && -f "$DEST/COPYING" && -f "$DEST/REVISION.txt" ]]; then
  if ! grep -Fq "Pinned commit: $PINNED_COMMIT" "$DEST/REVISION.txt"; then
    cache_reason="REVISION.txt does not identify pinned commit $PINNED_COMMIT"
  elif [[ "$(sha256_file "$DEST/picorv32.v")" != "$PINNED_SOURCE_SHA256" ]]; then
    cache_reason="picorv32.v does not match the pinned source hash $PINNED_SOURCE_SHA256"
  else
    cache_reason=""
  fi
fi

if [[ -z "$cache_reason" ]]; then
  echo "PicoRV32 is already vendored at pinned revision $PINNED_COMMIT"
  exit 0
fi

if [[ -e "$DEST" || -L "$DEST" ]]; then
  echo "ERROR: $DEST already contains a different/unpinned PicoRV32 source or incomplete cache: $cache_reason." >&2
  echo "Move it aside manually before re-vendoring; this script will not overwrite it." >&2
  exit 1
fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
echo "Cloning upstream PicoRV32..."
git clone --quiet "$REPO_URL" "$TMP_DIR/picorv32"
git -C "$TMP_DIR/picorv32" checkout --quiet --detach "$PINNED_COMMIT"
ACTUAL="$(git -C "$TMP_DIR/picorv32" rev-parse HEAD)"
if [[ "$ACTUAL" != "$PINNED_COMMIT" ]]; then
  echo "ERROR: requested $PINNED_COMMIT but checked out $ACTUAL" >&2
  exit 1
fi
mkdir -p "$DEST"
cp "$TMP_DIR/picorv32/picorv32.v" "$DEST/picorv32.v"
cp "$TMP_DIR/picorv32/COPYING" "$DEST/COPYING"
cat > "$DEST/REVISION.txt" <<EOF
Project: PicoRV32
Upstream: $REPO_URL
Pinned commit: $PINNED_COMMIT
File vendored: picorv32.v
Checkout is detached and verified before copying.
EOF
echo "Vendored PicoRV32 revision verified: $ACTUAL"
echo "Source: $DEST/picorv32.v"
