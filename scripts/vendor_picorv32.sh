#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_URL="https://github.com/YosysHQ/picorv32.git"
PINNED_COMMIT="ef203c2b0a3fb793280f5114941416c425c5b461"
DEST="vendor/picorv32"
if [[ -f "$DEST/picorv32.v" && -f "$DEST/REVISION.txt" ]] && grep -q "$PINNED_COMMIT" "$DEST/REVISION.txt"; then
  echo "PicoRV32 is already vendored at pinned revision $PINNED_COMMIT"
  exit 0
fi
if [[ -e "$DEST/picorv32.v" ]]; then
  echo "ERROR: $DEST already contains a different/unpinned PicoRV32 source." >&2
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
