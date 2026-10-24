#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CC="${RISCV_CC:-riscv64-elf-gcc}"
OBJCOPY="${RISCV_OBJCOPY:-riscv64-elf-objcopy}"
command -v "$CC" >/dev/null 2>&1 || { echo "ERROR: compiler not found: $CC" >&2; exit 1; }
command -v "$OBJCOPY" >/dev/null 2>&1 || { echo "ERROR: objcopy not found: $OBJCOPY" >&2; exit 1; }
mkdir -p build
"$CC" -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -nostartfiles \
  -Wl,--no-relax -Wl,-T,firmware/nexus32_smoke.ld \
  -Wl,-Map,build/nexus32_protected_access.map \
  firmware/nexus32_protected_access.S -o build/nexus32_protected_access.elf
"$OBJCOPY" -O binary build/nexus32_protected_access.elf build/nexus32_protected_access.bin
python3 scripts/bin_to_memh.py build/nexus32_protected_access.bin build/nexus32_protected_access.hex 4096
printf 'Protected-access firmware build passed: build/nexus32_protected_access.elf\n'
printf 'Protected-access IMEM image ready: build/nexus32_protected_access.hex\n'
