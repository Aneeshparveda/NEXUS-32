#!/usr/bin/env python3
"""Generate the T3-2 case-A expected vector for the CPU-driven block bench.

Case A (the shipped block stimulus, see T3-2 spec section 1.1 / 2):
  1024 samples of +1.0 (raw Q16.16 value 65536),
  coefficients [0.5, 0.25, 0.25] = [32768, 16384, 16384],
  TAP_COUNT = 3, sequential architecture.
Expected outputs: [32768, 49152] + [65536] * 1022.

Output format (T3-2 section 3.1, closed decision):
  exactly 1024 lines, one word per line, 8 lowercase hex digits,
  zero-padded, two's complement for negatives, each line terminated,
  no address prefixes, no comments, no blank lines, no extra trailing
  line beyond the final newline of line 1024.

The script prints one line: ``Generated <path> lines=1024 sha256=<hex>``.
It does NOT check the SHA against the case-A anchor itself; the runner
(``scripts/run_soc_block_1024.sh``) does that gate before simulating, so
a generator-input drift stops the run instead of silently passing.
No seed, no RNG: inputs are fixed constants, reproducibility is the SHA.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

# Repo root is the parent of this script's directory (repo/scripts/).
REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from golden_model.fir_q16 import fir_block_q16_16

SAMPLES = [65536] * 1024
COEFFICIENTS = [32768, 16384, 16384]


def main(argv: list[str]) -> int:
    output_path = Path(argv[1]) if len(argv) > 1 else REPO_ROOT / "build" / "block_1024_expected.mem"
    outputs = fir_block_q16_16(SAMPLES, COEFFICIENTS)
    if len(outputs) != 1024:
        print(f"ERROR: expected 1024 outputs, got {len(outputs)}", file=sys.stderr)
        return 1
    # Sanity pins from T3-2 section 2, case A. These are checks on the
    # generator's own inputs, not a patch to the golden model.
    if outputs[0] != 32768 or outputs[1] != 49152 or outputs[2] != 65536 or outputs[1023] != 65536:
        print(f"ERROR: case-A head/tail mismatch: {outputs[:3]} ... {outputs[1023]}", file=sys.stderr)
        return 1
    text = "".join(f"{value & 0xFFFFFFFF:08x}\n" for value in outputs)
    data = text.encode("ascii")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    print(f"Generated {output_path} lines=1024 sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
