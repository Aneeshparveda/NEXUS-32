#!/usr/bin/env bash
# NEXUS-32 FIR Core Characterization Runner
# Requires Vivado on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/results/vivado_core}"

if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: 'vivado' command not found on PATH." >&2
    echo "Vivado must be installed and initialized in this environment to run synthesis characterization." >&2
    exit 127
fi

echo "================================================================="
echo "NEXUS-32 FIR Core Characterization"
echo "Vivado executable: $(command -v vivado)"
vivado -version | head -n 1
echo "Repository root  : $REPO_ROOT"
echo "Output directory : $OUTPUT_DIR"
echo "================================================================="

mkdir -p "$OUTPUT_DIR"
cd "$REPO_ROOT"

vivado -mode batch -nojournal -nolog -source "$REPO_ROOT/vivado/run_core_characterization.tcl" -tclargs "$OUTPUT_DIR"

echo "================================================================="
echo "Characterization complete."
echo "Results summary: $OUTPUT_DIR/characterization_summary.md"
echo "================================================================="
