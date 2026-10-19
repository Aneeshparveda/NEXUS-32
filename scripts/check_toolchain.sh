#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

find_on_path() {
  local name="$1"
  local resolved

  resolved="$(type -P -- "$name" 2>/dev/null || true)"
  if [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  return 1
}

resolve_readelf() {
  local compiler="$1"
  local compiler_name="${compiler##*/}"
  local compiler_dir=""
  local candidate
  local resolved
  local target

  if [[ "$compiler" == */* ]]; then
    compiler_dir="${compiler%/*}"
    [[ -n "$compiler_dir" ]] || compiler_dir="/"
  fi

  # Prefer the binutils executable next to a compiler whose name carries the
  # usual GCC suffix, then try the same prefixed name on PATH.
  if [[ "$compiler_name" == *gcc ]]; then
    candidate="${compiler_name%gcc}readelf"
    if [[ -n "$compiler_dir" && -f "$compiler_dir/$candidate" && -x "$compiler_dir/$candidate" ]]; then
      printf '%s\n' "$compiler_dir/$candidate"
      return 0
    fi
    if resolved="$(find_on_path "$candidate")"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  # A custom compiler filename may not expose its target prefix. Ask GCC for
  # the target triplet before falling back to an unprefixed readelf.
  target="$("$compiler" -dumpmachine 2>/dev/null || true)"
  if [[ -n "$target" ]]; then
    candidate="${target}-readelf"
    if [[ -n "$compiler_dir" && -f "$compiler_dir/$candidate" && -x "$compiler_dir/$candidate" ]]; then
      printf '%s\n' "$compiler_dir/$candidate"
      return 0
    fi
    if resolved="$(find_on_path "$candidate")"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  if resolved="$(find_on_path readelf)"; then
    printf '%s\n' "$resolved"
    return 0
  fi
  return 1
}

if [[ -n "${RISCV_CC+x}" ]]; then
  if [[ -z "$RISCV_CC" ]]; then
    die "RISCV_CC is set but empty; provide an executable name or path"
  fi

  if [[ "$RISCV_CC" == */* ]]; then
    if [[ ! -f "$RISCV_CC" || ! -x "$RISCV_CC" ]]; then
      die "RISCV_CC does not name an executable file: $RISCV_CC"
    fi
    CC="$RISCV_CC"
  elif ! CC="$(find_on_path "$RISCV_CC")"; then
    die "RISCV_CC compiler was not found on PATH: $RISCV_CC"
  fi
  CC_SELECTION="RISCV_CC"
else
  if CC="$(find_on_path riscv64-elf-gcc)"; then
    CC_SELECTION="riscv64-elf-gcc"
  elif CC="$(find_on_path riscv64-unknown-elf-gcc)"; then
    CC_SELECTION="riscv64-unknown-elf-gcc"
  else
    die "no supported RISC-V compiler found; install riscv64-elf-gcc or riscv64-unknown-elf-gcc, or set RISCV_CC to an executable"
  fi
fi

if ! COMPILER_VERSION="$("$CC" --version 2>&1)"; then
  die "unable to run selected compiler: $CC"
fi

if ! READELF="$(resolve_readelf "$CC")"; then
  die "unable to locate readelf for selected compiler: $CC"
fi

if ! FILE_TOOL="$(find_on_path file)"; then
  die "required file utility was not found on PATH"
fi

printf '[1/3] Selected compiler (%s): %s\n' "$CC_SELECTION" "$CC"
printf '%s\n' "$COMPILER_VERSION" | head -n 1

TMP_DIR=""
if ! TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nexus32-toolchain.XXXXXX")"; then
  die "unable to create a temporary directory"
fi

cleanup() {
  local exit_code="$1"

  trap - EXIT
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    if ! rm -rf -- "$TMP_DIR"; then
      printf 'ERROR: failed to remove temporary directory: %s\n' "$TMP_DIR" >&2
      [[ "$exit_code" -ne 0 ]] || exit_code=1
    fi
  fi
  exit "$exit_code"
}
trap 'cleanup "$?"' EXIT

cat > "$TMP_DIR/smoke.c" <<'SRC'
#include <stdint.h>
int32_t fir_smoke(int32_t x, int32_t h) {
    int64_t product = (int64_t)x * (int64_t)h;
    return (int32_t)(product >> 16);
}
SRC

echo "[2/3] Compile exact RV32I/ILP32 target"
if ! "$CC" -march=rv32i -mabi=ilp32 -ffreestanding -fno-builtin -Wall -Wextra -Werror \
    -c "$TMP_DIR/smoke.c" -o "$TMP_DIR/smoke.o"; then
  die "selected compiler failed the RV32I/ILP32 smoke compile"
fi

echo "[3/3] Confirm object architecture"
if ! "$FILE_TOOL" "$TMP_DIR/smoke.o"; then
  die "file utility failed to inspect the smoke-test object"
fi
printf 'readelf: %s\n' "$READELF"
if ! READELF_HEADER="$("$READELF" -h "$TMP_DIR/smoke.o" 2>/dev/null)"; then
  die "readelf failed to report the smoke-test object architecture"
fi
if [[ ! "$READELF_HEADER" =~ Class:[[:space:]]+ELF32([[:space:]]|$) ]]; then
  die "smoke-test object is not an ELF32 object"
fi
if [[ ! "$READELF_HEADER" =~ Data:[[:space:]]+2\'s[[:space:]]complement,[[:space:]]+little[[:space:]]endian ]]; then
  die "smoke-test object is not little-endian"
fi
if [[ ! "$READELF_HEADER" =~ Machine:[[:space:]]+RISC-V([[:space:]]|$) ]]; then
  die "smoke-test object is not a RISC-V object"
fi
printf '%s\n' "$READELF_HEADER" | grep -E 'Class:|Data:|Machine:'

echo "RV32I compiler smoke test passed."
