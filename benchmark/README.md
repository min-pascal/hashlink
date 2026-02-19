# HashLink Architecture Benchmark Suite

A portable benchmark suite for comparing HashLink performance across different builds, architectures, and platforms.

Typical use cases:
- **arm64 vs x86_64** on Apple Silicon (native vs Rosetta 2)
- **Native vs emulated** on any platform (e.g., ARM Linux native vs QEMU x86_64)
- **Build-to-build** regression testing after code changes

## Quick Start

```bash
cd hashlink/benchmark
./run_benchmark.sh
```

The script auto-detects `hl` builds in `../build-arm64/` and `../build-x86_64/`. If your builds are elsewhere, specify them:

```bash
HL_BUILD_A=/path/to/build-arm64  HL_BUILD_B=/path/to/build-x86_64  ./run_benchmark.sh
```

## Prerequisites

| Requirement | Install | Notes |
|---|---|---|
| Haxe compiler | [haxe.org](https://haxe.org) | Must be on `PATH` |
| HashLink build(s) | `make` in hashlink root | At least one `hl` binary + `libhl` |
| Python 3 | Pre-installed on macOS/Linux | Optional — used for comparison table |
| hyperfine | `brew install hyperfine` | Optional — statistical comparison mode |

## Usage

```bash
# Default: 5 iterations per test, auto-detect builds
./run_benchmark.sh

# Custom iteration count
./run_benchmark.sh 10

# Specify build directories explicitly
HL_BUILD_A=/my/arm64/build  HL_BUILD_B=/my/x86_64/build  ./run_benchmark.sh

# Custom labels for display
HL_LABEL_A="arm64 native"  HL_LABEL_B="x86_64 Rosetta"  ./run_benchmark.sh

# Single-build mode (benchmark one binary only)
HL_BUILD_A=/my/build  ./run_benchmark.sh

# Use hyperfine for statistical comparison (mean, stddev, min/max)
./run_benchmark.sh --hyperfine

# Increase timeout for slow machines (default: 300s)
HL_TIMEOUT=600  ./run_benchmark.sh
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `HL_BUILD_A` | Auto-detect `build-arm64` | Path to first HashLink build directory |
| `HL_BUILD_B` | Auto-detect `build-x86_64` | Path to second HashLink build directory |
| `HL_LABEL_A` | Directory name | Display label for Build A |
| `HL_LABEL_B` | Directory name | Display label for Build B |
| `HL_TIMEOUT` | `300` | Max seconds per run before timeout |
| `HASHLINK_ROOT` | Parent of `benchmark/` | Override hashlink root for auto-detection |

## What's Benchmarked

| Test | Category | What it measures |
|---|---|---|
| `fibonacci` | CPU / recursion | Recursive call overhead, branch prediction |
| `nbodies` | CPU / float | Floating-point arithmetic, struct field access |
| `binary-trees` | GC / allocation | Object allocation, garbage collection pressure |
| `float-array` | Memory / float | Sequential float array traversal |
| `int-array` | Memory / int | Sequential int array traversal |
| `string-ops` | Strings | StringBuf, indexOf, split |
| `hashmap` | Data structures | Map insert, lookup, iteration |
| `mandelbrot` | Compute | Float-heavy loop, scalar computation |
| `vtable-dispatch` | OOP / JIT | Polymorphic virtual method calls through class hierarchy |
| `matrix-math` | 3D math | 4×4 matrix multiply, point transforms |
| `closures` | Functional | Lambda/closure creation and invocation |
| `dynamic-type` | Runtime dispatch | Dynamic field access, type-dependent branching |
| `object-churn` | GC / lifecycle | Rapid small-object create/discard cycles |

## Sample Output

```
Comparison (build-arm64 vs build-x86_64):

  Test                   build-arm64  build-x86_64    Speedup
  ──────────────────── ──────────── ──────────── ──────────
  fibonacci               126.5ms      204.5ms    1.62x ←
  nbodies                  58.2ms       54.9ms    0.94x →
  binary-trees            298.4ms      623.8ms    2.09x ←
  ...
  closures                 90.9ms      188.2ms    2.07x ←
  object-churn            319.5ms      685.7ms    2.15x ←

  TOTAL                  1590.1ms     3006.3ms    1.89x

  build-arm64 is 1.89x faster overall
```

`←` = Build A is faster, `→` = Build B is faster.

## Platform Support

| Platform | Library path variable | Status |
|---|---|---|
| macOS (arm64 / x86_64) | `DYLD_LIBRARY_PATH` | ✅ Tested |
| Linux (arm64 / x86_64) | `LD_LIBRARY_PATH` | ✅ Supported |
| Windows (MSYS2/Cygwin) | `PATH` | ✅ Supported |

The `Benchmark.hx` source and compiled `benchmark.hl` bytecode are fully cross-platform. Only the `hl` binary and `libhl` shared library need to match the target platform/architecture.

## Adding New Benchmarks

Edit `Benchmark.hx` and add a static function that returns a checksum:

```haxe
/** Description of what this tests */
static function benchMyTest():Dynamic {
    var checksum = 0;
    // ... workload ...
    return checksum;  // Prevents dead-code elimination
}
```

Register it in `main()`:

```haxe
bench("my-test", iters, benchMyTest);
```

Run `haxe benchmark.hxml` to recompile, then `./run_benchmark.sh`.

## Troubleshooting

### "haxe not found on PATH"
Install Haxe from [haxe.org](https://haxe.org) and ensure `haxe` is in your shell's `PATH`.

### "No HashLink builds found"
The script couldn't locate an `hl` binary. Either:
- Build hashlink: `cd hashlink && make`
- Or specify the path: `HL_BUILD_A=/path/to/build ./run_benchmark.sh`

### "crashed (exit code 127)" or "Symbol not found"
Your `libhl` shared library is missing symbols or mismatched with the `hl` binary. Rebuild:
```bash
cd hashlink && make clean_o && make
```

### Results vary between runs
Increase iterations for more stable averages:
```bash
./run_benchmark.sh 20
```
Or use `--hyperfine` which reports standard deviation and detects outliers.
