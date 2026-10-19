#!/usr/bin/env python3
"""Dependency-free consistency checks for the Basys-3 wrapper and XDC."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REQUIRED_PORTS = {"clk_100mhz", "btn_center", "led[0]", "led[1]", "led[2]", "led[3]"}


def _module_header(top_text: str) -> str:
    match = re.search(r"\bmodule\s+top_basys3\b(?P<header>.*?);", top_text, re.DOTALL)
    if match is None:
        raise ValueError("module top_basys3 with an ANSI port list was not found")
    return match.group("header")


def _declared_ports(top_text: str) -> dict[str, tuple[int, int] | None]:
    """Return scalar ports and packed vector ranges from the ANSI header."""

    header = _module_header(top_text)
    ports: dict[str, tuple[int, int] | None] = {}
    declaration = re.compile(
        r"\b(?:input|output|inout)\b\s+"
        r"(?:(?:wire|logic|reg|signed|unsigned)\s+)*"
        r"(?:(\[\s*\d+\s*:\s*\d+\s*\])\s+)?"
        r"([A-Za-z_]\w*)"
    )
    for match in declaration.finditer(header):
        packed_range, name = match.groups()
        if packed_range is None:
            ports[name] = None
            continue
        bounds = re.fullmatch(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", packed_range)
        if bounds is None:
            raise ValueError(f"unsupported packed range on port {name}: {packed_range}")
        ports[name] = (int(bounds.group(1)), int(bounds.group(2)))
    return ports


def _xdc_port_references(xdc_text: str) -> list[str]:
    references: list[str] = []
    pattern = re.compile(r"\[\s*get_ports\s+(?:\{([^}]*)\}|([^\s\]]+))\s*\]")
    for match in pattern.finditer(xdc_text):
        references.append((match.group(1) or match.group(2)).strip())
    return references


def _reference_exists(reference: str, ports: dict[str, tuple[int, int] | None]) -> bool:
    if reference in ports:
        return True
    bit_match = re.fullmatch(r"([A-Za-z_]\w*)\[(\d+)\]", reference)
    if bit_match is None:
        return False
    vector_name, bit_text = bit_match.groups()
    bounds = ports.get(vector_name)
    if bounds is None:
        return False
    bit = int(bit_text)
    high, low = bounds
    return min(high, low) <= bit <= max(high, low)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    top_path = root / "rtl" / "top_basys3.sv"
    xdc_path = root / "constraints" / "basys3.xdc"

    try:
        top_text = top_path.read_text(encoding="utf-8")
        xdc_text = xdc_path.read_text(encoding="utf-8")
        ports = _declared_ports(top_text)
        references = _xdc_port_references(xdc_text)
    except OSError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    missing_required = sorted(
        port for port in REQUIRED_PORTS
        if port not in references or not _reference_exists(port, ports)
    )
    unknown_references = sorted({ref for ref in references if not _reference_exists(ref, ports)})
    if missing_required:
        print("ERROR: required wrapper ports missing: " + ", ".join(missing_required), file=sys.stderr)
    if unknown_references:
        print("ERROR: XDC references undeclared ports: " + ", ".join(unknown_references), file=sys.stderr)
    if missing_required or unknown_references:
        return 1

    print(
        f"PASS: checked {len(references)} XDC get_ports references against "
        f"top_basys3 ({', '.join(sorted(REQUIRED_PORTS))})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
