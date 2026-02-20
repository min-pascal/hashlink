<#
.SYNOPSIS
    Build HashLink for Windows.

.DESCRIPTION
    Auto-detects architecture and builds using CMake with Visual Studio 2022.

.PARAMETER Preset
    CMake preset name. Auto-detected if not specified.
    Available: arm64-windows, x64-windows, x86-windows

.PARAMETER BuildType
    Build configuration: Release (default), Debug, RelWithDebInfo

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Preset arm64-windows
    .\build.ps1 -Preset x64-windows -BuildType Debug
#>

param(
    [string]$Preset = "",
    [string]$BuildType = "Release"
)

$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot

try {
    # Check for CMake
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
        Write-Error "CMake not found. Install from https://cmake.org/download/ or 'winget install Kitware.CMake'"
    }

    # Auto-detect preset
    if (-not $Preset) {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        switch ($arch) {
            "Arm64" { $Preset = "arm64-windows" }
            "X64"   { $Preset = "x64-windows" }
            "X86"   { $Preset = "x86-windows" }
            default { $Preset = "x64-windows" }
        }
    }

    Write-Host "==> Architecture: $([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
    Write-Host "==> Using CMake preset: $Preset"
    Write-Host ""

    cmake --preset $Preset
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

    cmake --build --preset $Preset --config $BuildType
    if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

    # Determine output directory
    $buildDirMap = @{
        "arm64-windows" = "build-arm64-windows"
        "x64-windows"   = "build-x64-windows"
        "x86-windows"   = "build-x86-windows"
    }
    $buildDir = $buildDirMap[$Preset]
    if (-not $buildDir) { $buildDir = "build" }

    Write-Host ""
    Write-Host "Build complete. Binaries are in: $buildDir\bin\"
}
finally {
    Pop-Location
}
