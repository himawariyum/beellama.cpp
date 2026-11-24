<#
.SYNOPSIS
  Builds beellama.cpp for Windows (CUDA / Vulkan / ROCm) and copies the complete
  set of binaries (exe + dll + runtime dependencies) to <repo>\dist.

.EXAMPLE
  .\deploy.ps1                         # interactive backend menu
  .\deploy.ps1 -Backend cuda
  .\deploy.ps1 -Backend cuda -CudaArch "86;89"
  .\deploy.ps1 -Backend rocm -GpuTargets gfx1100
  .\deploy.ps1 -Backend vulkan -Clean
#>

# --- Configuration ---
$TarballUrl  = "https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx103X-all-10.1.0.tar.gz"
$DownloadPath = "$env:TEMP\therock-dist-windows-gfx103X-all-10.1.0.tar.gz"
$ExtractPath  = "C:\TheRock"   # You can change this to your preferred location

# --- Step 1: Download the tarball ---
Write-Host "Downloading ROCm tarball from $TarballUrl ..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $TarballUrl -OutFile $DownloadPath -UseBasicParsing
    Write-Host "Download completed: $DownloadPath" -ForegroundColor Green
}
catch {
    Write-Error "Failed to download the tarball. $_"
    exit 1
}

# --- Step 2: Create extraction directory if it doesn't exist ---
if (-not (Test-Path -LiteralPath $ExtractPath)) {
    New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null
    Write-Host "Created directory: $ExtractPath" -ForegroundColor Green
}

# --- Step 3: Extract the tarball using the native tar command ---
Write-Host "Extracting archive to $ExtractPath ..." -ForegroundColor Cyan
try {
    tar -xzf $DownloadPath -C $ExtractPath
    Write-Host "Extraction completed." -ForegroundColor Green
}
catch {
    Write-Error "Failed to extract the archive. $_"
    exit 1
}

# --- Step 4: Determine the actual root folder after extraction ---
# The tarball usually extracts into a subfolder like "therock-dist-windows-gfx103X-all-10.1.0"
$ExtractedFolder = Get-ChildItem -LiteralPath $ExtractPath -Directory | Select-Object -First 1
if ($null -eq $ExtractedFolder) {
    Write-Error "No folder found in $ExtractPath after extraction."
    exit 1
}
$HipRoot = $ExtractedFolder.FullName
Write-Host "ROCm root directory: $HipRoot" -ForegroundColor Green

# --- Step 5: Set HIP_PATH environment variable (system-wide) ---
Write-Host "Setting HIP_PATH to $HipRoot ..." -ForegroundColor Cyan
try {
    [Environment]::SetEnvironmentVariable("HIP_PATH", $HipRoot, "Machine")
    Write-Host "HIP_PATH set successfully." -ForegroundColor Green
}
catch {
    Write-Error "Failed to set HIP_PATH. $_"
    exit 1
}

# --- Step 6: Add %HIP_PATH%\lib\llvm\bin to PATH (system-wide) ---
$LlmvBinPath = Join-Path $HipRoot "lib\llvm\bin"
if (-not (Test-Path -LiteralPath $LlmvBinPath)) {
    Write-Warning "The expected LLVM bin directory does not exist: $LlmvBinPath"
    Write-Warning "PATH will still be updated, but verify the path is correct."
}

Write-Host "Adding $LlmvBinPath to system PATH ..." -ForegroundColor Cyan
try {
    $CurrentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($CurrentPath -notlike "*$LlmvBinPath*") {
        $NewPath = "$CurrentPath;$LlmvBinPath"
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "Machine")
        Write-Host "PATH updated successfully." -ForegroundColor Green
    }
    else {
        Write-Host "PATH already contains $LlmvBinPath. Skipping." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Failed to update PATH. $_"
    exit 1
}

# --- Cleanup: Remove the downloaded tarball (optional) ---
Remove-Item -LiteralPath $DownloadPath -Force -ErrorAction SilentlyContinue

[CmdletBinding()]
param(
    [ValidateSet('cuda', 'vulkan', 'rocm')]
    [string]$Backend,

    # CUDA only: e.g. "86" (RTX 30xx), "89" (RTX 40xx), "86;89". Empty = native GPU detection.
    [string]$CudaArch = '',

    # ROCm only: e.g. "gfx1100" or "gfx1030;gfx1100". Empty = all default targets (slow build, big dist).
    [string]$GpuTargets = '',

    # Delete the build directory before configuring.
    [switch]$Clean,

    # Parallel build jobs.
    [int]$Jobs = [Environment]::ProcessorCount,

    # Pass -DGGML_NATIVE=OFF for a portable CPU build (default: ON, tuned for this machine).
    [switch]$NoNative,

    # CUDA/ROCm: compile FlashAttention kernels for ALL K/V cache type pairs (incl. every
    # asymmetric KVarN combo such as kvarn6/kvarn4). Much longer build and bigger DLLs.
    [switch]$AllQuants,

    # Pin an older MSVC toolset, e.g. "14.44" (VS 2022). Only needed if the HIP build fails with
    # "cannot overload __host__ __device__ function" errors on a very new Visual Studio.
    [string]$VcVarsVer = ''
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "WARNING: $msg" -ForegroundColor Yellow }
function Fail($msg)       { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { Fail "'$Exe' failed with exit code $LASTEXITCODE" }
}

# Loads the MSVC build environment (cl, link, Windows SDK, VS-bundled cmake/ninja) into this process.

function Import-VsEnv {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer\vswhere.exe'

    $vsPath = $null

    # Prefer Visual Studio 2022 Build Tools.
    $buildToolsPath = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\2022\BuildTools'

    $buildToolsVcvars = Join-Path $buildToolsPath `
        'VC\Auxiliary\Build\vcvars64.bat'

    if (Test-Path $buildToolsVcvars) {
        $vsPath = $buildToolsPath
    }
    elseif (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
    }

    if (-not $vsPath) {
        Fail 'Visual Studio 2022 Build Tools with the MSVC x64 toolset is required.'
    }

    $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'

    if (-not (Test-Path $vcvars)) {
        Fail "vcvars64.bat not found at $vcvars"
    }

    Write-Host "Loading MSVC environment from: $vsPath"

    $verArg = ''
    if ($VcVarsVer) {
        $verArg = "-vcvars_ver=$VcVarsVer"
    }

    cmd /c "`"$vcvars`" $verArg >nul 2>&1 && set" |
        ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') {
                [Environment]::SetEnvironmentVariable(
                    $Matches[1],
                    $Matches[2],
                    'Process'
                )
            }
        }

    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        Fail 'cl.exe still not found after loading vcvars64.bat.'
    }
}


# The HIP SDK's CMake config links hip::host against
#   <clang resource dir>\lib\x86_64-pc-windows-msvc\clang_rt.builtins.lib
# but some SDK packages ship the library under a different name/folder
# (e.g. lib\windows\clang_rt.builtins-x86_64.lib). Ninja then fails with
# "clang_rt.builtins.lib, needed by ggml-hip.lib, missing". Copy it to the expected place.
function Repair-HipBuiltins([string]$Hip) {
    $res = (& "$Hip\lib\llvm\bin\clang.exe" --print-resource-dir 2>$null | Select-Object -First 1)
    if (-not $res) { Write-Warn 'Could not query clang resource dir; skipping builtins check.'; return }
    $res = $res.Trim()

    $expected = Join-Path $res 'lib\x86_64-pc-windows-msvc\clang_rt.builtins.lib'
    if (Test-Path $expected) { return }

    $src = Get-ChildItem (Join-Path $res 'lib') -Recurse -Filter 'clang_rt.builtins*x86_64*.lib' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $src) {
        Fail "HIP SDK is missing the clang builtins library (expected $expected, nothing similar under $res\lib). Reinstall the HIP SDK with all components, or try 7.1.1 / newer."
    }

    Write-Host "Fixing HIP SDK layout: $($src.FullName)`n  -> $expected"
    try {
        New-Item -ItemType Directory -Path (Split-Path $expected) -Force -ErrorAction Stop | Out-Null
        Copy-Item $src.FullName $expected -Force -ErrorAction Stop
    } catch {
        Write-Host ''
        Write-Host 'Cannot write into the HIP SDK folder (needs admin). Run this once in an ELEVATED PowerShell, then re-run deploy:' -ForegroundColor Yellow
        Write-Host "  New-Item -ItemType Directory -Force '$(Split-Path $expected)'; Copy-Item '$($src.FullName)' '$expected'"
        exit 1
    }
}

# Copies files matching any pattern from any of the given dirs. Returns number of files copied.
function Copy-Runtime {
    param([string[]]$Dirs, [string[]]$Patterns, [string]$Dest)
    $count = 0
    foreach ($p in $Patterns) {
        $found = $false
        foreach ($d in $Dirs) {
            if (-not (Test-Path $d)) { continue }
            foreach ($f in (Get-ChildItem -Path $d -Filter $p -File -ErrorAction SilentlyContinue)) {
                Copy-Item $f.FullName $Dest -Force
                Write-Host "  + $($f.Name)"
                $count++; $found = $true
            }
            if ($found) { break }
        }
        if (-not $found) { Write-Warn "Runtime file not found: $p" }
    }
    return $count
}

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
if ($env:OS -ne 'Windows_NT') { Fail 'This script supports Windows only.' }

$Root = $PSScriptRoot
if (-not (Test-Path (Join-Path $Root 'CMakeLists.txt'))) {
    Fail "CMakeLists.txt not found next to this script. Put deploy.ps1 in the project root ($Root)."
}
Set-Location $Root

# ----------------------------------------------------------------------------
# Backend selection
# ----------------------------------------------------------------------------
if (-not $Backend) {
    Write-Host ''
    Write-Host 'Select backend to build:' -ForegroundColor Green
    Write-Host '  [1] CUDA    (NVIDIA)'
    Write-Host '  [2] Vulkan  (any GPU)'
    Write-Host '  [3] ROCm    (AMD HIP)'
    while (-not $Backend) {
        switch ((Read-Host 'Enter 1-3').Trim().ToLower()) {
            { $_ -in '1', 'cuda' }   { $Backend = 'cuda' }
            { $_ -in '2', 'vulkan' } { $Backend = 'vulkan' }
            { $_ -in '3', 'rocm', 'hip' } { $Backend = 'rocm' }
            default { Write-Warn 'Invalid choice.' }
        }
    }
}

if ($Backend -eq 'rocm' -and -not $PSBoundParameters.ContainsKey('GpuTargets')) {
    $GpuTargets = (Read-Host 'AMD GPU target(s), e.g. gfx1100 or gfx1030;gfx1100 (empty = all defaults)').Trim()
}

Write-Step "Backend: $($Backend.ToUpper())"

# ----------------------------------------------------------------------------
# Toolchain detection
# ----------------------------------------------------------------------------
Import-VsEnv

if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) {
    Fail 'cmake not found. Install CMake or the "C++ CMake tools for Windows" VS component.'
}
$HaveNinja = [bool](Get-Command ninja.exe -ErrorAction SilentlyContinue)

$CMakeArgs = @(
    '-DCMAKE_BUILD_TYPE=Release',
    '-DLLAMA_BUILD_TESTS=OFF',
    '-DLLAMA_BUILD_EXAMPLES=ON',
    '-DLLAMA_BUILD_SERVER=ON',
	'-DCMAKE_CROSSCOMPILING=ON'
)
if ($NoNative) { $CMakeArgs += '-DGGML_NATIVE=OFF' } else { $CMakeArgs += '-DGGML_NATIVE=ON' }

$RuntimeDirs     = @()   # where to look for runtime DLLs
$RuntimePatterns = @()
$ExtraDirCopies  = @()   # @{ Src=..; Dest=.. } directory trees to copy into dist

switch ($Backend) {
    'cuda' {
        $nvcc = Get-Command nvcc.exe -ErrorAction SilentlyContinue
        if (-not $nvcc) { Fail 'nvcc not found. Install the CUDA Toolkit (and make sure it is on PATH).' }
        $cudaRoot = Split-Path (Split-Path $nvcc.Source)
        Write-Host "CUDA toolkit: $cudaRoot"

        $CMakeArgs += '-DGGML_CUDA=ON', '-DGGML_CUDA_FA=ON', '-DGGML_CUDA_KVARN=ON'
        if ($AllQuants) { $CMakeArgs += '-DGGML_CUDA_FA_ALL_QUANTS=ON' }
        if ($CudaArch) { $CMakeArgs += "-DCMAKE_CUDA_ARCHITECTURES=$CudaArch" }

        $RuntimeDirs     = @("$cudaRoot\bin", "$cudaRoot\bin\x64")
        $RuntimePatterns = @('cudart64_*.dll', 'cublas64_*.dll', 'cublasLt64_*.dll')
    }
    'vulkan' {
        if (-not $env:VULKAN_SDK) { Fail 'VULKAN_SDK is not set. Install the LunarG Vulkan SDK.' }
        Write-Host "Vulkan SDK: $env:VULKAN_SDK"
        $CMakeArgs += '-DGGML_VULKAN=ON'
        # vulkan-1.dll comes from the GPU driver, nothing to bundle.
    }
    'rocm' {
        if (-not $env:HIP_PATH) { Fail 'HIP_PATH is not set. Install the AMD HIP SDK for Windows.' }
        $hip = $env:HIP_PATH.TrimEnd('\')
        if (-not (Test-Path "$Hip\lib\llvm\bin\clang.exe")) { Fail "clang.exe not found in $hip\bin." }
        if (-not $HaveNinja) { Fail 'Ninja is required for the ROCm build (install it or the VS CMake component).' }
        Write-Host "HIP SDK: $hip"

        $env:PATH = "$hip\bin;$hip\lib\llvm\bin;$env:PATH"
        Repair-HipBuiltins $hip
        # hip-config.cmake aborts with "Unexpected HIP_PLATFORM" when this is empty/unset.
        $env:HIP_PLATFORM = 'amd'
        $CMakeArgs += '-DGGML_HIP=ON', '-DHIP_PLATFORM=amd',
                      '-DGGML_CUDA_FA=ON', '-DGGML_CUDA_KVARN=ON',   # KVarN kernels are shared CUDA/HIP
                      '-DCMAKE_C_COMPILER=clang', '-DCMAKE_CXX_COMPILER=clang++'
        if ($AllQuants) { $CMakeArgs += '-DGGML_CUDA_FA_ALL_QUANTS=ON' }
        if ($GpuTargets) { $CMakeArgs += "-DGPU_TARGETS=$GpuTargets" }

        $RuntimeDirs     = @("$hip\bin")
        $RuntimePatterns = @('amdhip64*.dll', 'amd_comgr*.dll', 'hiprtc*.dll', 'hipblas.dll',
                             'libhipblas.dll', 'rocblas.dll', 'libhipblaslt.dll', 'hipblaslt.dll',
							 'rocm_kpack.dll', 'rocsolver.dll')
        $ExtraDirCopies  = @(
            @{ Src = "$hip\bin\rocblas\library";   Dest = 'rocblas\library' },
            @{ Src = "$hip\bin\hipblaslt\library"; Dest = 'hipblaslt\library' }
        )
    }
}

if ($HaveNinja) { $CMakeArgs = @('-G', 'Ninja') + $CMakeArgs }

# ----------------------------------------------------------------------------
# Configure + build
# ----------------------------------------------------------------------------
$BuildDir = Join-Path $Root "build-$Backend"
if ($Clean -and (Test-Path $BuildDir)) {
    Write-Step "Cleaning $BuildDir"
    Remove-Item $BuildDir -Recurse -Force
}

Write-Step 'Configuring'
Invoke-Native 'cmake' (@('-S', $Root, '-B', $BuildDir) + $CMakeArgs)

Write-Step "Building ($Jobs jobs)"
Invoke-Native 'cmake' @('--build', $BuildDir, '--config', 'Release', '--parallel', $Jobs)

# ----------------------------------------------------------------------------
# Locate build output
# ----------------------------------------------------------------------------
$BinDir = @("$BuildDir\bin\Release", "$BuildDir\bin") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $BinDir) { Fail "Build output directory not found under $BuildDir\bin" }

$built = Get-ChildItem $BinDir -File | Where-Object { $_.Extension -in '.exe', '.dll' }
if (-not ($built | Where-Object { $_.Name -eq 'llama-server.exe' })) {
    Fail "llama-server.exe was not produced in $BinDir"
}

# ----------------------------------------------------------------------------
# Deploy to dist
# ----------------------------------------------------------------------------
$Dist = Join-Path $Root 'dist'
Write-Step "Deploying to $Dist"
if (Test-Path $Dist) { Get-ChildItem $Dist -Force | Remove-Item -Recurse -Force }
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

foreach ($f in $built) { Copy-Item $f.FullName $Dist -Force }
Write-Host "Copied $($built.Count) binaries from $BinDir"

if ($RuntimePatterns.Count -gt 0) {
    Write-Host 'Bundling runtime dependencies:'
    [void](Copy-Runtime -Dirs $RuntimeDirs -Patterns $RuntimePatterns -Dest $Dist)
}

# ROCm math-library kernel data (optionally filtered to requested GPU targets)
foreach ($d in $ExtraDirCopies) {
    if (-not (Test-Path $d.Src)) { Write-Warn "Missing: $($d.Src)"; continue }
    $dest = Join-Path $Dist $d.Dest
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    $targets = @()
    if ($GpuTargets) { $targets = $GpuTargets -split '[;,\s]+' | Where-Object { $_ } | ForEach-Object { ($_ -split ':')[0] } }

    $n = 0
    foreach ($f in (Get-ChildItem $d.Src -File)) {
        $isArchSpecific = $f.Name -match 'gfx\d+'
        $keep = (-not $targets) -or (-not $isArchSpecific) -or ($targets | Where-Object { $f.Name -like "*$_*" })
        if ($keep) { Copy-Item $f.FullName $dest -Force; $n++ }
    }
    Write-Host "  + $($d.Dest) ($n files)"
}

# Verify the binary exposes KVarN cache types (--cache-type-k / --cache-type-v)
Write-Step 'Verifying KVarN support'
$helpText = (& (Join-Path $Dist 'llama-server.exe') --help 2>&1 | Out-String)
$kvarnOk = $helpText -match 'kvarn'
if ($kvarnOk) {
    Write-Host 'OK: kvarn types are listed in --cache-type-k / --cache-type-v' -ForegroundColor Green
} else {
    Write-Warn 'Could not find "kvarn" in llama-server --help. Make sure you are building the BeeLlama fork, not upstream llama.cpp.'
}

# Build info
@"
backend:  $Backend
built:    $(Get-Date -Format 's')
commit:   $(try { (git rev-parse --short HEAD 2>$null) } catch { 'n/a' })
cuda_arch: $CudaArch
gpu_targets: $GpuTargets
all_fa_quants: $AllQuants
kvarn_detected: $kvarnOk
"@ | Set-Content (Join-Path $Dist 'build-info.txt') -Encoding ASCII

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
$size = [math]::Round(((Get-ChildItem $Dist -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ''
Write-Host "Done. $Backend build deployed to: $Dist ($size MB)" -ForegroundColor Green
Write-Host "Try:  $Dist\llama-server.exe -m model.gguf --flash-attn on --cache-type-k kvarn4 --cache-type-v kvarn4 --kv-tail-tokens 1024"
