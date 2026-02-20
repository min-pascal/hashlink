<a href="https://hashlink.haxe.org"><img src="https://hashlink.haxe.org/hashlink.svg" alt="HashLink" align="right" /></a>

# HashLink

[![Build Status](https://dev.azure.com/HaxeFoundation/GitHubPublic/_apis/build/status/HaxeFoundation.hashlink?branchName=master)](https://dev.azure.com/HaxeFoundation/GitHubPublic/_build/latest?definitionId=4&branchName=master)
[![Build Status](https://github.com/HaxeFoundation/hashlink/workflows/Build/badge.svg "GitHub Actions")](https://github.com/HaxeFoundation/hashlink/actions?query=workflow%3ABuild)

### HashLink is a virtual machine for Haxe <https://hashlink.haxe.org>

## ARM64 Support

HashLink natively supports ARM64 (Apple Silicon, Linux aarch64, Windows ARM64) with a dedicated JIT compiler. On ARM64 hosts, the correct JIT is selected automatically by both CMake and Make.

### Quick Build with CMake Presets

The easiest way to build for any platform is with [CMake presets](CMakePresets.json):

```bash
# Auto-detect architecture (works everywhere)
cmake --preset default && cmake --build --preset default

# Or pick a specific target:
cmake --preset arm64-macos && cmake --build --preset arm64-macos   # Apple Silicon
cmake --preset arm64-linux && cmake --build --preset arm64-linux   # Linux aarch64
cmake --preset arm64-windows && cmake --build --preset arm64-windows  # Windows ARM64 (VS 2022)
```

Prerequisites: CMake 3.21+ and Ninja (or Visual Studio 2022 on Windows). Install Ninja via your package manager (`brew install ninja`, `apt install ninja-build`, etc.).

### Quick Build Script

Alternatively, use the provided wrapper scripts:

```bash
# macOS / Linux
./build.sh

# Windows (PowerShell)
.\build.ps1
```

These auto-detect your architecture and build with sensible defaults.

## Building on Linux/OSX

HashLink is distributed with some graphics libraries allowing to develop various applications, you can manually disable the libraries you want to compile in Makefile.
Here's the dependencies that you install in order to compile all the libraries:

* fmt: libpng-dev libturbojpeg-dev libvorbis-dev
* openal: libopenal-dev
* sdl: libsdl2-dev libglu1-mesa-dev
* ssl: libmbedtls-dev
* uv: libuv1-dev
* sqlite: libsqlite3-dev

To install all dependencies on the latest **Ubuntu**, for example:

`sudo apt-get install libpng-dev libturbojpeg-dev libvorbis-dev libopenal-dev libsdl2-dev libglu1-mesa-dev libmbedtls-dev libuv1-dev libsqlite3-dev`

For 16.04, see [this note](https://github.com/HaxeFoundation/hashlink/issues/147).

To install all dependencies on the latest **Fedora**, for example:

`sudo dnf install libpng-devel turbojpeg-devel libvorbis-devel openal-soft-devel SDL2-devel mesa-libGLU-devel mbedtls-devel libuv-devel  sqlite-devel`

**And on OSX:**

`brew bundle` to install the dependencies listed in [Brewfile](Brewfile).

Once dependencies are installed you can simply call:

`make`

To be able to use hashlink binary with the debugger you can then call:

`sudo make codesign_osx`

To install hashlink binaries on your system you can then call:

`make install`

## Building on Windows

Open `hl.sln` using Visual Studio C++ and compile (x86/x64 targets).

For **ARM64 Windows**, use CMake instead:

```powershell
cmake --preset arm64-windows
cmake --build --preset arm64-windows
```

To build all of HashLink libraries it is required to download several additional distributions, read each library README file (in hashlink/libs/xxx/README.md) for additional information.

In short you'll probably need:

- [SDL2-devel](https://github.com/libsdl-org/SDL/releases/download/release-2.30.12/SDL2-devel-2.30.12-VC.zip), extract to `<hashlink>/include/sdl`
- [openal-soft](https://github.com/kcat/openal-soft/releases/download/1.23.1/openal-soft-1.23.1-bin.zip), extract to `<hashlink>/include/openal`

## Debugging

You can debug Haxe/HashLink applications by using the [Visual Studio Code Debugger](https://marketplace.visualstudio.com/items?itemName=HaxeFoundation.haxe-hl)

## Documentation

Read the [Documentation](https://github.com/HaxeFoundation/hashlink/wiki) on the HashLink wiki.
