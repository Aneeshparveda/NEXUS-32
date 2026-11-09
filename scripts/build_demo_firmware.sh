#!/usr/bin/env bash
# Build the board demo firmware: golden constants from the Python model, then
# the RV32I image. Output: firmware/nexus32_demo.hex (gitignored, bundled).
set -euo pipefail
cd "$(dirname "$0")/.."
CC="${RISCV_CC:-riscv64-elf-gcc}"
OBJCOPY="${RISCV_OBJCOPY:-riscv64-elf-objcopy}"
command -v "$CC" >/dev/null 2>&1 || { echo "ERROR: compiler not found: $CC" >&2; exit 1; }
command -v "$OBJCOPY" >/dev/null 2>&1 || { echo "ERROR: objcopy not found: $OBJCOPY" >&2; exit 1; }
mkdir -p build
python3 scripts/gen_demo_expected.py build/nexus32_demo_expected.inc
"$CC" -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -nostartfiles \
  -Ibuild \
  -Wl,--no-relax -Wl,-T,firmware/nexus32_smoke.ld \
  -Wl,-Map,build/nexus32_demo.map \
  firmware/nexus32_demo.S -o build/nexus32_demo.elf
"$OBJCOPY" -O binary build/nexus32_demo.elf build/nexus32_demo.bin
python3 scripts/bin_to_memh.py build/nexus32_demo.bin firmware/nexus32_demo.hex 4096
printf 'Demo firmware build passed: build/nexus32_demo.elf\n'
printf 'IMEM image ready: firmware/nexus32_demo.hex\n'
