#Requires -Version 5.1
<#
.SYNOPSIS
    Patches a Flutter SDK's Windows embedder to report graphics-context loss, then builds
    the engine so a project can be built against it.

.DESCRIPTION
    Stock Flutter has no detection and no recovery for EGL_CONTEXT_LOST on Windows. When a
    GPU driver resets, the rasterizer stops drawing permanently while the message loop and
    the Dart isolate carry on, so the window freezes with no other symptom and no way for
    the app to find out. This patch adds two exports that let the host be told:

        FlutterDesktopSetGraphicsContextLostNotification(hwnd, message)
        FlutterDesktopIsGraphicsContextLost()

    See README.md for the background and example\ for how to use them.

.PARAMETER FlutterRoot
    The unzipped Flutter SDK - the folder containing bin\flutter.bat. Unzipping
    flutter_windows_3.44.8-stable.zip into C:\src gives C:\src\flutter, so that is the
    path to pass.

.PARAMETER DepotTools
    Where to keep depot_tools. Downloaded if not already present. Defaults to a
    depot_tools folder beside FlutterRoot.

.PARAMETER VisualStudioPath
    Visual Studio 2022 install root. Auto-detected via vswhere when omitted. Detection is
    pinned to 17.x on purpose: the engine's GN toolchain only knows 2019/2022, so a
    machine that also has VS 2026 must not be allowed to pick it.

.PARAMETER SkipSync
    Skip 'gclient sync'. Only safe on a re-run where the sync already completed - it is by
    far the slowest step, so this makes iterating on the patch quick.

.EXAMPLE
    .\patch-and-build.ps1 -FlutterRoot C:\src\flutter
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FlutterRoot,

    [string]$DepotTools,

    [string]$VisualStudioPath,

    [switch]$SkipSync
)

$ErrorActionPreference = 'Stop'
$started = [System.Diagnostics.Stopwatch]::StartNew()

# The SDK version this patch was generated against. A different version is not
# automatically wrong - the patched functions are small and self-contained - but the
# context lines may not match, so say so before git apply fails with something cryptic.
$ExpectedVersion = '3.44.8'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "    $Message" -ForegroundColor Yellow
}

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Quiet) {
            # 2>&1 merges stderr into the success stream so it never reaches the error
            # stream in the first place.
            $null = & $FilePath @Arguments 2>&1
        }
        else {
            & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        }
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

# ---------------------------------------------------------------- validate the SDK tree

Write-Step 'Validating the Flutter SDK'

if (-not (Test-Path $FlutterRoot)) {
    Fail "FlutterRoot does not exist: $FlutterRoot"
}
$FlutterRoot = (Resolve-Path $FlutterRoot).Path

if (-not (Test-Path (Join-Path $FlutterRoot 'bin\flutter.bat'))) {
    Fail @"
$FlutterRoot does not look like a Flutter SDK (no bin\flutter.bat).
Unzipping the SDK archive creates a 'flutter' folder - pass that folder, not its parent.
"@
}

# gclient and git apply both operate on the repo, so this has to be a real checkout.
if (-not (Test-Path (Join-Path $FlutterRoot '.git'))) {
    Fail @"
$FlutterRoot has no .git directory.
The official SDK archives are git checkouts and this script needs that: gclient reads the
repo to resolve DEPS, and the patch is applied with 'git apply'. If .git was stripped,
clone the SDK instead:
    git clone --branch $ExpectedVersion https://github.com/flutter/flutter.git
"@
}

# The engine sources live in the monorepo. Without them there is nothing to patch.
$EglSource = Join-Path $FlutterRoot 'engine\src\flutter\shell\platform\windows\egl\egl.cc'
if (-not (Test-Path $EglSource)) {
    Fail @"
Engine sources are missing from this SDK:
    $EglSource
This script patches and rebuilds the Windows embedder, which needs the engine source tree
that ships in the flutter/flutter monorepo. Clone the SDK instead of using the archive:
    git clone --branch $ExpectedVersion https://github.com/flutter/flutter.git
"@
}
Write-Ok "SDK root:     $FlutterRoot"

# The archives carry the version in bin\cache\flutter.version.json. There is no top-level
# 'version' file - that only exists in some older/cloned layouts - so try both.
$actualVersion = $null
$versionJson = Join-Path $FlutterRoot 'bin\cache\flutter.version.json'
$versionFile = Join-Path $FlutterRoot 'version'
if (Test-Path $versionJson) {
    try {
        $actualVersion = (Get-Content $versionJson -Raw | ConvertFrom-Json).frameworkVersion
    }
    catch {
        # Malformed or partially written cache file is not a reason to stop; git apply
        # below is the real compatibility check.
        $actualVersion = $null
    }
}
elseif (Test-Path $versionFile) {
    $actualVersion = (Get-Content $versionFile -Raw).Trim()
}

if (-not $actualVersion) {
    Write-Warn "Could not determine the SDK version (expected $ExpectedVersion)."
}
elseif ($actualVersion -eq $ExpectedVersion) {
    Write-Ok "SDK version:  $actualVersion"
}
else {
    Write-Warn "SDK version is $actualVersion but this patch was made for $ExpectedVersion."
    Write-Warn 'If the patch does not apply, that mismatch is why.'
}

$PatchFile = Join-Path $PSScriptRoot '0001-windows-report-egl-context-loss.patch'
if (-not (Test-Path $PatchFile)) {
    Fail "Patch file not found next to this script: $PatchFile"
}
Write-Ok "Patch:        $PatchFile"

# Resolve git BEFORE depot_tools goes on PATH. depot_tools ships a git.bat shim that runs
# git through cmd, which changes how its output is surfaced; asking for git.exe explicitly
# keeps the patch steps on a plain executable.
$GitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
if (-not $GitExe) {
    Fail 'git.exe was not found on PATH. Install Git for Windows.'
}
Write-Ok "Git:          $GitExe"

# ------------------------------------------------------------------- locate the toolchain

Write-Step 'Locating Visual Studio 2022'

if (-not $VisualStudioPath) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        Fail 'vswhere.exe not found. Install Visual Studio 2022 with "Desktop development with C++".'
    }

    # Pinned to 17.x. The engine's GN toolchain files only recognise VS 2019/2022, so on a
    # machine that also has a newer Visual Studio, letting it pick "latest" produces a
    # failure a long way into the build with no obvious cause.
    $VisualStudioPath = & $vswhere -version '[17.0,18.0)' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath -latest
}

if (-not $VisualStudioPath -or -not (Test-Path $VisualStudioPath)) {
    Fail @"
Visual Studio 2022 with the C++ toolset was not found.
Install it, or pass -VisualStudioPath explicitly.
"@
}
Write-Ok "Visual Studio: $VisualStudioPath"

$WindowsSdkDir = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
if (-not (Test-Path $WindowsSdkDir)) {
    Fail "Windows 10/11 SDK not found at $WindowsSdkDir"
}
Write-Ok "Windows SDK:   $WindowsSdkDir"

# ----------------------------------------------------------------------- get depot_tools

Write-Step 'Preparing depot_tools'

if (-not $DepotTools) {
    $DepotTools = Join-Path (Split-Path $FlutterRoot -Parent) 'depot_tools'
}

if (-not (Test-Path (Join-Path $DepotTools 'gclient.bat'))) {
    Write-Host "    downloading depot_tools to $DepotTools ..."
    New-Item -ItemType Directory -Force $DepotTools | Out-Null
    $zip = Join-Path $env:TEMP 'depot_tools.zip'
    Invoke-WebRequest -Uri 'https://storage.googleapis.com/chrome-infra/depot_tools.zip' `
        -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $DepotTools -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $DepotTools 'gclient.bat'))) {
    Fail "depot_tools is not usable at $DepotTools (no gclient.bat)"
}
Write-Ok "depot_tools:   $DepotTools"

# ------------------------------------------------------------------- build environment
#
# These MUST be set in this process. Setting them at User scope does not reach children of
# an already-running shell, and the failure that causes is misleading: vs_toolchain.py sees
# DEPOT_TOOLS_WIN_TOOLCHAIN unset, tries to download Google's internal toolchain from the
# chrome-wintoolchain bucket, and dies on a 401 that says nothing about the real cause.

$env:PATH = "$DepotTools;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:GYP_MSVS_OVERRIDE_PATH = $VisualStudioPath
$env:GYP_MSVS_VERSION = '2022'
$env:WINDOWSSDKDIR = $WindowsSdkDir

# ------------------------------------------------------------------------ sync engine deps

Write-Step 'Syncing engine dependencies'

$gclientFile = Join-Path $FlutterRoot '.gclient'
if (-not (Test-Path $gclientFile)) {
    $template = Join-Path $FlutterRoot 'engine\scripts\standard.gclient'
    if (-not (Test-Path $template)) {
        Fail "Missing $template - cannot bootstrap gclient."
    }
    Copy-Item $template $gclientFile -Force
    Write-Ok 'wrote .gclient'
}

if ($SkipSync) {
    Write-Warn 'skipped (-SkipSync)'
}
else {
    Write-Host '    running gclient sync - first run downloads ~16 GB and takes a while ...'
    Push-Location $FlutterRoot
    try {
        # gclient writes progress and git-config advice to stderr even on success, which
        # is fatal under Windows PowerShell 5.1 without this wrapper.
        $syncExit = Invoke-Native -FilePath (Join-Path $DepotTools 'gclient.bat') `
            -Arguments @('sync', '-D')
        if ($syncExit -ne 0) {
            Fail "gclient sync failed with exit code $syncExit"
        }
    }
    finally {
        Pop-Location
    }
    Write-Ok 'dependencies synced'
}

# ------------------------------------------------------------------------- apply the patch

Write-Step 'Applying the patch'

# --reverse --check succeeds only when the patch is already present, which makes re-runs
# safe: this script is expected to be run again after a sync failure or an SDK refresh.
# It is EXPECTED to fail (noisily, on stderr) on an unpatched tree - hence -Quiet and
# Invoke-Native rather than calling git directly.
$reverseCheck = Invoke-Native -FilePath $GitExe -Quiet `
    -Arguments @('-C', $FlutterRoot, 'apply', '--reverse', '--check', $PatchFile)

if ($reverseCheck -eq 0) {
    Write-Ok 'already applied - nothing to do'
}
else {
    $forwardCheck = Invoke-Native -FilePath $GitExe -Quiet `
        -Arguments @('-C', $FlutterRoot, 'apply', '--check', $PatchFile)

    if ($forwardCheck -ne 0) {
        # Re-run without -Quiet so the actual conflict is visible before we stop.
        Write-Warn 'git reported:'
        $null = Invoke-Native -FilePath $GitExe `
            -Arguments @('-C', $FlutterRoot, 'apply', '--check', $PatchFile)
        Fail @"
The patch does not apply cleanly to this SDK.
Most likely the SDK version differs from $ExpectedVersion. Regenerate the patch against
this version, or use an SDK matching it.
"@
    }

    $applied = Invoke-Native -FilePath $GitExe `
        -Arguments @('-C', $FlutterRoot, 'apply', $PatchFile)
    if ($applied -ne 0) {
        Fail "git apply failed with exit code $applied"
    }
    Write-Ok 'patch applied'
}

# -------------------------------------------------------------------------- build the engine

Write-Step 'Building the engine (host_release)'

$et = Join-Path $FlutterRoot 'engine\src\flutter\bin\et.bat'
if (-not (Test-Path $et)) {
    Fail "Engine build tool not found: $et"
}

Push-Location (Join-Path $FlutterRoot 'engine\src\flutter')
try {
    $buildExit = Invoke-Native -FilePath $et -Arguments @('build', '-c', 'host_release')
    if ($buildExit -ne 0) {
        Fail "Engine build failed with exit code $buildExit"
    }
}
finally {
    Pop-Location
}

# ------------------------------------------------------------------------------- verify

Write-Step 'Verifying the built engine'

$EngineSrc = Join-Path $FlutterRoot 'engine\src'
$OutDir = Join-Path $EngineSrc 'out\host_release'
$Dll = Join-Path $OutDir 'flutter_windows.dll'

if (-not (Test-Path $Dll)) {
    Fail "Build reported success but $Dll is missing."
}

# Look for the export names as raw bytes. The export directory stores them as plain ASCII,
# so this needs no external tool - dumpbin is not on PATH in a default shell, and requiring
# a Visual Studio developer prompt just to check two strings is not worth it.
$bytes = [System.IO.File]::ReadAllBytes($Dll)
$text = [System.Text.Encoding]::ASCII.GetString($bytes)
$missing = @()
foreach ($symbol in @('FlutterDesktopSetGraphicsContextLostNotification',
                      'FlutterDesktopIsGraphicsContextLost')) {
    if ($text.IndexOf($symbol, [StringComparison]::Ordinal) -ge 0) {
        Write-Ok "exports $symbol"
    }
    else {
        $missing += $symbol
    }
}
if ($missing.Count -gt 0) {
    Fail "Built engine is missing: $($missing -join ', '). The patch did not take effect."
}

$header = Join-Path $OutDir 'flutter_windows.h'
if (Test-Path $header) {
    if ((Get-Content $header -Raw).Contains('FlutterDesktopIsGraphicsContextLost')) {
        Write-Ok 'published flutter_windows.h carries the new API'
    }
    else {
        Fail 'Published flutter_windows.h does not declare the new API.'
    }
}

$started.Stop()

Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host " Patched engine ready in $([math]::Round($started.Elapsed.TotalMinutes,1)) min" -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Build your project against it with:'
Write-Host ''
Write-Host '  flutter build windows --release `' -ForegroundColor White
Write-Host "    --local-engine-src-path $EngineSrc ``" -ForegroundColor White
Write-Host '    --local-engine host_release `' -ForegroundColor White
Write-Host '    --local-engine-host host_release' -ForegroundColor White
Write-Host ''
Write-Host 'Notes:'
Write-Host '  - These flags are required. Without them flutter build uses the prebuilt'
Write-Host '    engine in bin\cache\artifacts and the patch has no effect.'
Write-Host "  - Put $FlutterRoot\bin on PATH so this SDK is the one that runs."
Write-Host '  - If your project gates the integration behind a compile-time define, set it'
Write-Host '    and run "flutter clean" first - CMake caches environment variables.'
Write-Host '  - See example\ for a drop-in watchdog and the runner wiring.'
Write-Host ''
