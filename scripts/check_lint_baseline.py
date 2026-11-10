#!/usr/bin/env python3
"""Fail when Verilator reports a project-RTL warning outside the reviewed baseline.

Usage: check_lint_baseline.py <verilator-lint.log> [baseline]
       check_lint_baseline.py --self-test

Baseline lines are "RULE path max_count". A warning is unexpected when its
rule/file pair is absent from the baseline or its count exceeds max_count.
Warnings in vendor/ are third-party (pinned PicoRV32) and are not gated.
Verilator errors are not handled here: they already fail the lint command.
"""
import re
import sys
from collections import Counter
from pathlib import Path

DEFAULT_BASELINE = Path(__file__).with_name("lint_baseline.txt")
WARNING = re.compile(r"^%Warning(?:-([A-Z0-9_]+))?: ([^:\s]+):\d+")


def unexpected(log_text: str, baseline_text: str) -> list[str]:
    allowed: dict[tuple[str, str], int] = {}
    for raw in baseline_text.splitlines():
        fields = raw.split("#", 1)[0].split()
        if fields:
            rule, path, max_count = fields
            allowed[(rule, path)] = int(max_count)

    seen: Counter[tuple[str, str]] = Counter()
    for line in log_text.splitlines():
        match = WARNING.match(line)
        if match and not match.group(2).startswith("vendor/"):
            seen[(match.group(1) or "UNNAMED", match.group(2))] += 1

    return [
        f"{rule} {path}: {count} seen, {allowed.get((rule, path), 0)} allowed"
        for (rule, path), count in sorted(seen.items())
        if count > allowed.get((rule, path), 0)
    ]


def self_test() -> None:
    baseline = "# reviewed\nPINCONNECTEMPTY rtl/a.sv 2  # optional pins\n"
    clean = (
        "%Warning-PINCONNECTEMPTY: rtl/a.sv:10:5: Cell pin connected by name\n"
        "%Warning-PINCONNECTEMPTY: rtl/a.sv:11:5: Cell pin connected by name\n"
        "%Warning-WIDTH: vendor/picorv32/picorv32.v:99:1: third-party\n"
        "                 : ... note: continuation lines are ignored\n"
    )
    assert unexpected(clean, baseline) == []
    assert unexpected(clean + "%Warning-WIDTH: rtl/a.sv:20:3: new\n", baseline) == [
        "WIDTH rtl/a.sv: 1 seen, 0 allowed"
    ]
    assert unexpected(
        clean + "%Warning-PINCONNECTEMPTY: rtl/a.sv:12:5: third\n", baseline
    ) == ["PINCONNECTEMPTY rtl/a.sv: 3 seen, 2 allowed"]
    assert unexpected("%Warning: rtl/b.sv:1:1: unnamed\n", baseline) == [
        "UNNAMED rtl/b.sv: 1 seen, 0 allowed"
    ]
    print("PASS: lint baseline checker self-test")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    log_path = Path(sys.argv[1])
    baseline_path = Path(sys.argv[2]) if len(sys.argv) == 3 else DEFAULT_BASELINE
    problems = unexpected(log_path.read_text(), baseline_path.read_text())
    if problems:
        print(f"FAIL: Verilator warnings outside {baseline_path}:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("Fix the RTL, or review the warning and update the baseline.", file=sys.stderr)
        return 1
    print(f"PASS: no project-RTL Verilator warning outside {baseline_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
