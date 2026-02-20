#!/usr/bin/env bash
#
# Benchmark configuration — edit the paths below for your environment.
#
# Usage:
#   ./bench.sh          # Run with defaults (5 iterations)
#   ./bench.sh 10       # 10 iterations
#   ./bench.sh --hyperfine
#

# ── Edit these paths ──────────────────────────────────────────
# Point each to a directory containing: hl (or hl.exe) + libhl
export HL_BUILD_A="/path/to/build-arm64"
export HL_BUILD_B="/path/to/build-x86_64"

# ── Optional: display labels ─────────────────────────────────
export HL_LABEL_A="arm64 native"
export HL_LABEL_B="x86_64 emulated"

# ── Optional: timeout per run (seconds) ──────────────────────
# export HL_TIMEOUT=300

# ── Run ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/run_benchmark.sh" "${@:-5}"
