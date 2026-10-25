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
  -Wl,-Map,build/nexus32_block_1024.map \
  firmware/nexus32_block_1024.S -o build/nexus32_block_1024.elf
"$OBJCOPY" -O binary build/nexus32_block_1024.elf build/nexus32_block_1024.bin
python3 scripts/bin_to_memh.py build/nexus32_block_1024.bin build/nexus32_block_1024.hex 4096
printf '1024-sample block firmware build passed: build/nexus32_block_1024.elf\n'
printf '1024-sample block IMEM image ready: build/nexus32_block_1024.hex\n'
