#!/usr/bin/env bash
set -euo pipefail

CC="${RISCV_CC:-riscv64-elf-gcc}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/smoke.c" <<'SRC'
#include <stdint.h>
volatile int32_t fir_smoke(int32_t x, int32_t h) {
    int64_t product = (int64_t)x * (int64_t)h;
    return (int32_t)(product >> 16);
}
SRC

echo "[1/3] Compiler identity"
"$CC" --version | head -n 1

echo "[2/3] Compile exact RV32I/ILP32 target"
"$CC" -march=rv32i -mabi=ilp32 -ffreestanding -fno-builtin -Wall -Wextra -Werror \
  -c "$TMP_DIR/smoke.c" -o "$TMP_DIR/smoke.o"

echo "[3/3] Confirm object architecture"
file "$TMP_DIR/smoke.o"
"${CC%gcc}readelf" -h "$TMP_DIR/smoke.o" 2>/dev/null | grep -E 'Class:|Data:|Machine:' || true

echo "RV32I compiler smoke test passed."
