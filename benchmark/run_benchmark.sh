#!/usr/bin/env bash
#
# HashLink Architecture Benchmark Runner
# Compares two HashLink builds side-by-side (e.g., arm64 vs x86_64, native vs emulated).
#
# Usage:
#   ./run_benchmark.sh                          # Auto-detect builds, 5 iterations
#   ./run_benchmark.sh 10                       # 10 iterations per test
#   ./run_benchmark.sh --hyperfine              # Use hyperfine for statistics
#
# Specify build directories:
#   HL_BUILD_A=/path/to/build-arm64  HL_BUILD_B=/path/to/build-x86_64  ./run_benchmark.sh
#
# Single-build mode (benchmark one binary only):
#   HL_BUILD_A=/path/to/build  ./run_benchmark.sh
#
# Custom labels (shown in output):
#   HL_LABEL_A="arm64 native"  HL_LABEL_B="x86_64 Rosetta"  ./run_benchmark.sh
#
# Auto-detection searches for hl binaries in:
#   1. HL_BUILD_A / HL_BUILD_B environment variables
#   2. <hashlink_root>/build-arm64  and  <hashlink_root>/build-x86_64
#   3. <hashlink_root>/build
#
# Prerequisites:
#   - Haxe compiler (haxe) on PATH        https://haxe.org
#   - At least one hl build directory containing: hl (or hl.exe) + shared library
#   - Python 3 (for comparison table; optional)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR"
BENCH_HL="$BENCH_DIR/benchmark.hl"
TMPDIR_BENCH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BENCH"' EXIT

# Max seconds to wait for a single run before killing it
TIMEOUT_SECS="${HL_TIMEOUT:-300}"

# ── Platform detection ────────────────────────────────────────
UNAME="$(uname -s)"
case "$UNAME" in
    Darwin)
        LIB_PATH_VAR="DYLD_LIBRARY_PATH"
        HL_BIN_NAME="hl"
        LIB_NAME="libhl.dylib"
        ;;
    Linux)
        LIB_PATH_VAR="LD_LIBRARY_PATH"
        HL_BIN_NAME="hl"
        LIB_NAME="libhl.so"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        LIB_PATH_VAR="PATH"
        HL_BIN_NAME="hl.exe"
        LIB_NAME="libhl.dll"
        ;;
    *)
        LIB_PATH_VAR="LD_LIBRARY_PATH"
        HL_BIN_NAME="hl"
        LIB_NAME="libhl.so"
        ;;
esac

# ── Auto-detect hashlink root ────────────────────────────────
# Assumes this script lives in <hashlink>/benchmark/
HASHLINK_ROOT="${HASHLINK_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

find_hl_build() {
    local env_val="$1"   # value from env var (may be empty)
    local hint="$2"      # architecture hint: "arm64", "x86_64", or ""

    # 1. Explicit env var — path to a build directory or binary
    if [ -n "$env_val" ]; then
        if [ -f "$env_val/$HL_BIN_NAME" ]; then
            echo "$env_val"
            return
        fi
        if [ -f "$env_val" ] && [[ "$(basename "$env_val")" == "$HL_BIN_NAME" ]]; then
            dirname "$env_val"
            return
        fi
    fi

    # 2. Search for build-<hint> directories under HASHLINK_ROOT
    if [ -n "$hint" ] && [ -f "$HASHLINK_ROOT/build-${hint}/$HL_BIN_NAME" ]; then
        echo "$HASHLINK_ROOT/build-${hint}"
        return
    fi

    # 3. Generic build/ directory
    if [ -f "$HASHLINK_ROOT/build/$HL_BIN_NAME" ]; then
        echo "$HASHLINK_ROOT/build"
        return
    fi

    echo ""
}

BUILD_A="$(find_hl_build "${HL_BUILD_A:-}" "arm64")"
BUILD_B="$(find_hl_build "${HL_BUILD_B:-}" "x86_64")"

# Labels default to directory basename or a generic name
default_label() {
    local dir="$1"
    local fallback="$2"
    if [ -n "$dir" ]; then
        basename "$dir"
    else
        echo "$fallback"
    fi
}

LABEL_A="${HL_LABEL_A:-$(default_label "$BUILD_A" "Build A")}"
LABEL_B="${HL_LABEL_B:-$(default_label "$BUILD_B" "Build B")}"

# ── Parse args ────────────────────────────────────────────────
ITERATIONS="${1:-5}"
USE_HYPERFINE=false

for arg in "$@"; do
    case "$arg" in
        --hyperfine) USE_HYPERFINE=true ;;
        [0-9]*)      ITERATIONS="$arg" ;;
    esac
done

# ── Colors (disabled if stdout is not a terminal) ─────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
    YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; CYAN=''; YELLOW=''; BOLD=''; NC=''
fi

# ── Helpers ───────────────────────────────────────────────────
info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
fail()  { echo -e "${RED}[fail]${NC}  $*"; exit 1; }
sep()   { echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Preflight checks ─────────────────────────────────────────
info "HashLink Architecture Benchmark"
sep

command -v haxe >/dev/null 2>&1 || fail "haxe not found on PATH. Install from https://haxe.org"
info "haxe version: $(haxe --version)"
info "platform:     $UNAME ($(uname -m))"

if [ -z "$BUILD_A" ] && [ -z "$BUILD_B" ]; then
    echo ""
    fail "No HashLink builds found.

  Specify build directories via environment variables:

    HL_BUILD_A=/path/to/build-arm64  HL_BUILD_B=/path/to/build-x86_64  $0

  Or place builds in the standard locations:
    $HASHLINK_ROOT/build-arm64/$HL_BIN_NAME
    $HASHLINK_ROOT/build-x86_64/$HL_BIN_NAME

  See README.md for full setup instructions."
fi

SINGLE_MODE=false
if [ -z "$BUILD_A" ] || [ -z "$BUILD_B" ]; then
    SINGLE_MODE=true
    if [ -z "$BUILD_A" ]; then
        BUILD_A="$BUILD_B"
        LABEL_A="$LABEL_B"
        BUILD_B=""
    fi
    warn "Only one build found ($LABEL_A). Running single-build mode."
    warn "Set HL_BUILD_B to add a second build for comparison."
fi

HL_A="${BUILD_A}/${HL_BIN_NAME}"
[ -f "$HL_A" ] || fail "$HL_BIN_NAME not found at $HL_A"
info "$LABEL_A:  $HL_A"
if command -v file >/dev/null 2>&1; then
    info "  arch: $(file -b "$HL_A" | head -c 60)"
fi

if ! $SINGLE_MODE; then
    HL_B="${BUILD_B}/${HL_BIN_NAME}"
    [ -f "$HL_B" ] || fail "$HL_BIN_NAME not found at $HL_B"
    info "$LABEL_B:  $HL_B"
    if command -v file >/dev/null 2>&1; then
        info "  arch: $(file -b "$HL_B" | head -c 60)"
    fi
fi

# ── Compile benchmark ────────────────────────────────────────
info "Compiling benchmark.hl ..."
cd "$BENCH_DIR"
haxe benchmark.hxml
[ -f "$BENCH_HL" ] || fail "Compilation failed – benchmark.hl not created"
ok "benchmark.hl compiled ($(wc -c < "$BENCH_HL" | tr -d ' ') bytes)"
sep

# ── Run with hyperfine (if requested) ────────────────────────
if $USE_HYPERFINE; then
    if ! command -v hyperfine >/dev/null 2>&1; then
        warn "hyperfine not installed."
        warn "  macOS:   brew install hyperfine"
        warn "  Linux:   cargo install hyperfine  (or apt/dnf)"
        warn "  Windows: scoop install hyperfine"
        warn "Falling back to built-in runner."
        USE_HYPERFINE=false
    fi
fi

if $USE_HYPERFINE && ! $SINGLE_MODE; then
    info "Running with hyperfine (statistical comparison)..."
    sep
    hyperfine \
        --warmup 2 \
        --runs "$ITERATIONS" \
        --export-markdown "$BENCH_DIR/results_hyperfine.md" \
        -n "$LABEL_A" \
        "$LIB_PATH_VAR=$BUILD_A $HL_A $BENCH_HL" \
        -n "$LABEL_B" \
        "$LIB_PATH_VAR=$BUILD_B $HL_B $BENCH_HL"
    sep
    ok "Markdown results saved to: $BENCH_DIR/results_hyperfine.md"
    exit 0
fi

# ── Built-in runner ──────────────────────────────────────────
# Runs hl in background with a watchdog timer. Writes output to a temp file
# to avoid hanging if the process crashes.
run_bench() {
    local label="$1"
    local hl_bin="$2"
    local outfile="$3"
    local lib_dir
    lib_dir="$(dirname "$hl_bin")"

    echo ""
    info "${BOLD}$label${NC}"
    echo ""

    # Set the platform-appropriate library path and run in background
    eval "$LIB_PATH_VAR=\"$lib_dir\"" "$hl_bin" "$BENCH_HL" "$ITERATIONS" \
        > "$outfile.raw" 2>&1 &
    local pid=$!

    # Watchdog: kill if still running after TIMEOUT_SECS
    ( sleep "$TIMEOUT_SECS" && kill "$pid" 2>/dev/null ) &
    local watchdog=$!

    wait "$pid" 2>/dev/null
    local rc=$?

    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null

    # Filter debug/JIT noise
    grep -v -E "^(DEBUG:|JIT CODE|PATCHING|DONE |CALLING ENTRY)" "$outfile.raw" > "$outfile" 2>/dev/null || true

    if [ $rc -eq 0 ]; then
        cat "$outfile"
        return 0
    else
        if [ $rc -eq 137 ] || [ $rc -eq 143 ]; then
            echo "BENCH_ERROR: $label TIMED OUT after ${TIMEOUT_SECS}s"
        else
            echo "BENCH_ERROR: $label crashed (exit code $rc)"
        fi
        cat "$outfile" 2>/dev/null | tail -5
        return 1
    fi
}

FILE_A="$TMPDIR_BENCH/build_a.txt"
FILE_B="$TMPDIR_BENCH/build_b.txt"

OK_A=true
OK_B=true

run_bench "$LABEL_A" "$HL_A" "$FILE_A" || OK_A=false

if ! $SINGLE_MODE; then
    run_bench "$LABEL_B" "$HL_B" "$FILE_B" || OK_B=false
fi

# ── Display results ──────────────────────────────────────────
sep
if $OK_A; then
    echo -e "${BOLD}Results: $LABEL_A${NC}"
    cat "$FILE_A"
else
    echo -e "${RED}$LABEL_A FAILED${NC}"
    cat "$FILE_A" 2>/dev/null || true
fi

if ! $SINGLE_MODE; then
    sep
    if $OK_B; then
        echo -e "${BOLD}Results: $LABEL_B${NC}"
        cat "$FILE_B"
    else
        echo -e "${RED}$LABEL_B FAILED${NC}"
        cat "$FILE_B" 2>/dev/null || true
        echo ""
        warn "Build B may need to be recompiled."
        warn "Check that $LIB_NAME is present and up to date in: $BUILD_B"
    fi
fi
sep

# ── Parse JSON and compare ───────────────────────────────────
if ! $SINGLE_MODE; then
    extract_json() {
        grep "^JSON:" "$1" 2>/dev/null | sed 's/^JSON: //' || echo ""
    }

    JSON_A=$(extract_json "$FILE_A")
    JSON_B=$(extract_json "$FILE_B")

    if $OK_A && $OK_B && [ -n "$JSON_A" ] && [ -n "$JSON_B" ]; then
        echo ""
        echo -e "${BOLD}Comparison ($LABEL_A vs $LABEL_B):${NC}"
        echo ""

        # Use python3 for JSON parsing (available on macOS and most Linux)
        python3 -c "
import json, sys

a_data = json.loads('''$JSON_A''')
b_data = json.loads('''$JSON_B''')
label_a = '$LABEL_A'
label_b = '$LABEL_B'

# Truncate labels for table formatting
la = label_a[:12]
lb = label_b[:12]

print(f'  {\"Test\":<20s} {la:>12s} {lb:>12s} {\"Speedup\":>10s}')
print(f'  {\"─\"*20:s} {\"─\"*12:s} {\"─\"*12:s} {\"─\"*10:s}')

for a, b in zip(a_data, b_data):
    name = a['name']
    a_ms = a['ms']
    b_ms = b['ms']
    if a_ms > 0:
        speedup = b_ms / a_ms
        arrow = '←' if speedup > 1 else '→'
        color = '\033[0;32m' if speedup > 1 else '\033[0;31m'
        nc = '\033[0m'
        print(f'  {name:<20s} {a_ms:>10.1f}ms {b_ms:>10.1f}ms {color}{speedup:>7.2f}x {arrow}{nc}')
    else:
        print(f'  {name:<20s} {a_ms:>10.1f}ms {b_ms:>10.1f}ms       N/A')

a_total = sum(r['ms'] for r in a_data)
b_total = sum(r['ms'] for r in b_data)
overall = b_total / a_total if a_total > 0 else 0
print()
print(f'  {\"TOTAL\":<20s} {a_total:>10.1f}ms {b_total:>10.1f}ms {overall:>7.2f}x')
print()
if overall > 1:
    print(f'  {label_a} is {overall:.2f}x faster overall')
else:
    print(f'  {label_b} is {1/overall:.2f}x faster overall')
" 2>/dev/null || warn "Could not parse results for comparison (python3 required)"
    elif ! $OK_A || ! $OK_B; then
        echo ""
        warn "Cannot compare — one or both runs failed."
    fi
fi

sep
ok "Benchmark complete."
echo ""
echo "Tips:"
echo "  • Specify builds:  HL_BUILD_A=/path/a HL_BUILD_B=/path/b $0"
echo "  • Custom labels:   HL_LABEL_A='native' HL_LABEL_B='emulated' $0"
echo "  • More iterations: $0 20"
echo "  • Use hyperfine:   $0 --hyperfine"
