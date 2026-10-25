#!/usr/bin/env python3
"""Convert a flat little-endian RV32 binary to 32-bit $readmemh words."""
from pathlib import Path
import sys

if len(sys.argv) != 4:
    raise SystemExit("usage: bin_to_memh.py input.bin output.hex word_count")
source = Path(sys.argv[1])
destination = Path(sys.argv[2])
word_count = int(sys.argv[3], 0)
if word_count <= 0:
    raise SystemExit("word_count must be positive")
payload = source.read_bytes()
capacity = 4 * word_count
if len(payload) > capacity:
    raise SystemExit(f"firmware is {len(payload)} bytes, exceeding IMEM capacity {capacity}")
payload += bytes(capacity - len(payload))
lines = []
for offset in range(0, len(payload), 4):
    word = int.from_bytes(payload[offset:offset + 4], byteorder="little", signed=False)
    lines.append(f"{word:08x}")
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n".join(lines) + "\n", encoding="ascii")
print(f"Wrote {word_count} 32-bit words to {destination} ({len(payload)} bytes)")
