#!/usr/bin/env bash
#
# build.sh — Build HashLink for the current platform and architecture.
#
# Usage:
#   ./build.sh                 # auto-detect everything
#   ./build.sh --preset NAME   # use a specific CMake preset
#   ./build.sh --make           # use Makefile instead of CMake
#
# Requirements: CMake 3.21+, Ninja (install via: brew install ninja / apt install ninja-build)
#
set -euo pipefail

cd "$(dirname "$0")"

BUILD_TYPE="RelWithDebInfo"
USE_MAKE=false
PRESET=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset)
            PRESET="$2"; shift 2 ;;
        --make)
            USE_MAKE=true; shift ;;
        --release)
            BUILD_TYPE="Release"; shift ;;
        --debug)
            BUILD_TYPE="Debug"; shift ;;
        -h|--help)
            echo "Usage: $0 [--preset NAME] [--make] [--release] [--debug]"
            echo ""
            echo "Options:"
            echo "  --preset NAME   Use a specific CMake preset (see CMakePresets.json)"
            echo "  --make          Use Makefile instead of CMake (Linux/macOS only)"
            echo "  --release       Build in Release mode"
            echo "  --debug         Build in Debug mode"
            echo ""
            echo "Available presets:"
            echo "  default          Auto-detect architecture"
            echo "  arm64-macos      Apple Silicon Mac"
            echo "  x64-macos        Intel Mac"
            echo "  arm64-linux      ARM64 Linux (aarch64)"
            echo "  x64-linux        x86_64 Linux"
            echo ""
            echo "Without --preset, the script auto-detects your platform and architecture."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"; exit 1 ;;
    esac
done

ARCH=$(uname -m)
OS=$(uname -s)

if $USE_MAKE; then
    echo "==> Building with Make (arch: $ARCH)"
    make clean_o 2>/dev/null || true
    make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
    echo ""
    echo "Build complete. Binaries are in the current directory."
    exit 0
fi

# Auto-detect preset if not specified
if [[ -z "$PRESET" ]]; then
    case "$OS" in
        Darwin)
            case "$ARCH" in
                arm64)   PRESET="arm64-macos" ;;
                x86_64)  PRESET="x64-macos" ;;
                *)       PRESET="default" ;;
            esac
            ;;
        Linux)
            case "$ARCH" in
                aarch64) PRESET="arm64-linux" ;;
                x86_64)  PRESET="x64-linux" ;;
                *)       PRESET="default" ;;
            esac
            ;;
        *)
            PRESET="default"
            ;;
    esac
fi

echo "==> Platform: $OS ($ARCH)"
echo "==> Using CMake preset: $PRESET"

# Check for CMake
if ! command -v cmake &>/dev/null; then
    echo "Error: CMake not found. Install it with:"
    echo "  macOS:  brew install cmake"
    echo "  Linux:  sudo apt install cmake"
    exit 1
fi

# Check for Ninja (preferred generator)
if ! command -v ninja &>/dev/null; then
    echo "Warning: Ninja not found. Install for faster builds:"
    echo "  macOS:  brew install ninja"
    echo "  Linux:  sudo apt install ninja-build"
    echo "Falling back to default generator..."
    # Use default preset which may work without Ninja
fi

cmake --preset "$PRESET"
cmake --build --preset "$PRESET" --parallel

# Find the output directory
BUILD_DIR=$(cmake --preset "$PRESET" 2>&1 | grep -oP '(?<=Build files have been written to: ).*' || true)
if [[ -z "$BUILD_DIR" ]]; then
    # Try to figure it out from preset name
    case "$PRESET" in
        default)          BUILD_DIR="build" ;;
        arm64-macos)      BUILD_DIR="build-arm64-macos" ;;
        x64-macos)        BUILD_DIR="build-x64-macos" ;;
        arm64-linux)      BUILD_DIR="build-arm64-linux" ;;
        x64-linux)        BUILD_DIR="build-x64-linux" ;;
        *)                BUILD_DIR="build" ;;
    esac
fi

echo ""
echo "Build complete. Binaries are in: $BUILD_DIR/bin/"
