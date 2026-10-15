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
  -Wl,-Map,build/nexus32_invalid_fetch.map \
  firmware/nexus32_invalid_fetch.S -o build/nexus32_invalid_fetch.elf
"$OBJCOPY" -O binary build/nexus32_invalid_fetch.elf build/nexus32_invalid_fetch.bin
python3 scripts/bin_to_memh.py build/nexus32_invalid_fetch.bin firmware/nexus32_invalid_fetch.hex 4096
printf 'Invalid-fetch firmware build passed: build/nexus32_invalid_fetch.elf\n'
printf 'Invalid-fetch IMEM image ready: firmware/nexus32_invalid_fetch.hex\n'
