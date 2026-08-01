# Flutter engine patch - report EGL context loss on Windows

Patches the Flutter Windows embedder so an application can be told when the graphics
context is permanently lost, and rebuilds the engine so projects can be built against it.

## The problem

A GPU page fault in the display driver makes Windows TDR the render engine, which removes
the process's D3D11 device. ANGLE's EGL display then enters permanent context loss.

Stock Flutter has **no detection and no recovery** for this. The only mention of
`EGL_CONTEXT_LOST` in the entire Windows embedder is an error-to-string entry, and nothing
recreates the display or contexts. The rasterizer silently stops drawing while the Win32
message loop and the Dart isolate carry on as normal - so the window freezes with no other
outward symptom, no exception, nothing in the logs, and the application has no way to find
out. It stays that way until the process is restarted.

### Why you cannot detect it from frame callbacks

`FlutterEngine::SetNextFrameCallback` fires per frame-pipeline iteration, **not** per
successful present.

Measured from two full memory dumps taken during a live freeze: the engine reported **60
completed frames per minute**, and answered a forced `ForceRedraw()`, while the
display had been dead for an hour. Every failure counter read zero.

So the engine has to report the loss itself.

## What the patch adds

Two exports, declared in `flutter_windows.h`:

```c
// Posts |message| to |hwnd| the first time the graphics context is permanently lost.
// Posted at most once per process. If the context was already lost, posts immediately,
// so registration order does not matter. Pass a null HWND to unregister.
void FlutterDesktopSetGraphicsContextLostNotification(HWND hwnd, UINT message);

// True once the graphics context has been permanently lost. Never returns to false.
bool FlutterDesktopIsGraphicsContextLost(void);
```

The notification is the fast path - measured at **19 ms** from driver fault to application
restart. The pollable flag is the guarantee, because `PostMessage` can fail and this is the
one failure a host cannot otherwise discover.

### How it works

The hook is `flutter::egl::LogEGLError` in
`engine/src/flutter/shell/platform/windows/egl/egl.cc`. Every EGL failure in the embedder
already funnels through that one function via the `WINDOWS_LOG_EGL_ERROR` macro -
`Context::MakeCurrent`, `Surface::MakeCurrent`, `Surface::SwapBuffers`,
`Surface::Destroy` - and it already calls `eglGetError()`. So the entire change is ~140
lines across 4 files and adds no new call sites.

The pollable flag is set unconditionally and first; notification is attempted afterwards
and retried on a later EGL failure if delivery failed, so a single dropped post is not
permanent.

## Requirements

- Windows x64
- **Visual Studio 2022** with "Desktop development with C++".
  The engine's GN toolchain only recognises VS 2019/2022. Detection is pinned to 17.x on
  purpose - on a machine that also has a newer Visual Studio, letting it pick "latest"
  fails a long way into the build with no obvious cause.
- Windows 10/11 SDK
- Git
- ~35 GB free disk and a fast connection (engine dependencies are ~16 GB)

`depot_tools` is downloaded automatically if not already present.

## Usage

1. Download the SDK archive matching the patch - currently **3.44.8**:

   <https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.44.8-stable.zip>

2. Unzip it. The archive contains a top-level `flutter` folder, so extracting to `C:\src`
   gives `C:\src\flutter`.

3. Run:

   ```powershell
   .\patch-and-build.ps1 -FlutterRoot C:\src\flutter
   ```

The script validates the SDK, fetches `depot_tools`, runs `gclient sync`, applies the
patch, builds `host_release`, and verifies the built DLL actually exports the new symbols.
It is safe to re-run: an already-applied patch is detected and skipped.

| Switch | Purpose |
| --- | --- |
| `-SkipSync` | Skip `gclient sync` on a re-run. By far the slowest step. |
| `-DepotTools <path>` | Reuse an existing depot_tools instead of downloading. |
| `-VisualStudioPath <path>` | Override Visual Studio detection. |

## Building your project against the patched engine

**The patched engine is not picked up automatically.**
Without `--local-engine`, `flutter build` uses the prebuilt artifacts in
`bin\cache\artifacts\engine\windows-x64` - stock binaries downloaded from Google. Patching
the source and building writes to `engine\src\out\host_release` and never touches that
cache, so applying the patch is necessary but not sufficient.

```powershell
flutter build windows --release `
  --local-engine-src-path C:\src\flutter\engine\src `
  --local-engine host_release `
  --local-engine-host host_release
```

Three things that will otherwise cost you time:

- **Put the patched SDK's `bin` on `PATH`.** `--local-engine` replaces the engine, not the
  framework, and a framework from a different SDK version is not guaranteed to match it.
- **`flutter clean` after changing any build-gating environment variable.** CMake does not
  track environment variables as configure dependencies, so the previous value persists in
  the cache and you will build the wrong thing while believing otherwise.
- **Verify what you shipped**, rather than assuming:

  ```powershell
  dumpbin /imports build\windows\x64\runner\Release\<your_app>.exe | findstr GraphicsContextLost
  ```

See [`example/`](example/) for a drop-in watchdog and the wiring needed in a stock Flutter
Windows runner, including how to keep the integration behind an `#ifdef` so the same source
still builds against an unpatched SDK.

## CI

A build server needs the same two things: the patched engine present, and the
`--local-engine` flags passed. Worth adding a step that fails early and says so, rather
than letting it surface as a compile error about missing declarations hundreds of lines
into a build:

```powershell
$header = Join-Path $env:FLUTTER_ENGINE_SRC 'out\host_release\flutter_windows.h'
if (-not (Test-Path $header)) {
  throw "No engine build at $env:FLUTTER_ENGINE_SRC. Run patch-and-build.ps1 on this runner."
}
if (-not (Select-String -Path $header -Pattern 'FlutterDesktopIsGraphicsContextLost' -Quiet)) {
  throw "The engine at $env:FLUTTER_ENGINE_SRC is not patched."
}
```

Keeping the engine path in a CI variable rather than hard-coded means it can move without
editing the workflow.

If your project gates the integration behind a compile-time define, set it on the release
build. A binary built without it still runs, but cannot detect a lost context - so it is
worth making that case fail loudly rather than ship quietly.

## Notes on the SDK archive

The official archives are full git checkouts and include the engine source tree, which is
what makes this work without a separate clone. Verified against 3.44.8: 22,212 entries,
6,810 under `engine/`, a packed `.git`, and a clean `git status` after extraction. They do
**not** include the engine's third-party dependencies - that is what `gclient sync` fetches.

If you use a checkout whose `.git` has been stripped, clone instead:

```powershell
git clone --branch 3.44.8 https://github.com/flutter/flutter.git
```

## Regenerating the patch for a newer SDK

```powershell
git -C <flutter-root> diff -- engine/src/flutter/shell/platform/windows > 0001-windows-report-egl-context-loss.patch
```

Then update `$ExpectedVersion` at the top of `patch-and-build.ps1`. The patched functions
are small and self-contained, so the patch has a fair chance of applying to nearby versions
unchanged; the script warns on a version mismatch rather than refusing outright.

## Testing it

Disabling and re-enabling the display adapter in Device Manager produces a real
`EGL_CONTEXT_LOST` and exercises the whole path end to end, without waiting for a driver
crash.
