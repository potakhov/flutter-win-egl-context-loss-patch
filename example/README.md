# Example — using the patched engine

A drop-in watchdog plus the wiring needed in a stock Flutter Windows runner.

| File | Purpose |
| --- | --- |
| `gpu_context_watchdog.h` / `.cpp` | Self-contained. Only dependencies are Win32 and `flutter_windows.h`. |

The snippets below are written against the **stock** `flutter create` Windows runner, so
line them up with your own `windows/runner/` and adapt names as needed.

## 1. Add the files

Copy both into `windows/runner/`. The template's `CMakeLists.txt` globs sources, so
usually no CMake change is needed for the files themselves — check yours:

```cmake
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "gpu_context_watchdog.cpp"   # add if your CMakeLists lists sources explicitly
  ...
)
```

## 2. Define `HAVE_FLUTTER_CONTEXT_LOSS_API` when building against the patched engine

The API exists only on a patched engine, so the integration is behind an `#ifdef` and the
same source still builds against a stock SDK.

In `windows/runner/CMakeLists.txt`:

```cmake
# Driven by an environment variable because the Flutter tool owns the cmake invocation
# and offers no way to pass -D through `flutter build`.
#
# NOTE: CMake does not track environment variables as configure dependencies, so run
# `flutter clean` after changing this or the previous value persists in the cache.
if(DEFINED ENV{HAVE_FLUTTER_CONTEXT_LOSS_API} AND NOT "$ENV{HAVE_FLUTTER_CONTEXT_LOSS_API}" STREQUAL "0")
  message(STATUS "Building WITH graphics context-loss detection")
  target_compile_definitions(${BINARY_NAME} PRIVATE "HAVE_FLUTTER_CONTEXT_LOSS_API")
else()
  message(WARNING
    "HAVE_FLUTTER_CONTEXT_LOSS_API is not set - building WITHOUT context-loss "
    "detection. This binary will freeze permanently if the GPU driver resets.")
endif()
```

Pick whatever macro name suits your project; just keep it consistent with the `.cpp`.

## 3. Wire it into `FlutterWindow`

In `flutter_window.h`:

```cpp
#include "gpu_context_watchdog.h"
...
 private:
  std::unique_ptr<GpuContextWatchdog> gpu_watchdog_;
```

In `flutter_window.cpp` — create it after the view controller exists:

```cpp
bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  // ... existing flutter_controller_ setup ...

  gpu_watchdog_ = std::make_unique<GpuContextWatchdog>(
      GetHandle(), [this]() { OnGraphicsContextLost(); });

  if (!GpuContextWatchdog::IsSupported()) {
    OutputDebugStringA(
        "WARNING: built without the patched engine - a GPU driver reset will "
        "freeze this app permanently and nothing will notice.\n");
  }

  return true;
}
```

Destroy it before the window goes away:

```cpp
void FlutterWindow::OnDestroy() {
  gpu_watchdog_.reset();   // owns a timer on this window
  // ... existing teardown ...
  Win32Window::OnDestroy();
}
```

And give it first look at messages:

```cpp
LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT message,
                                      WPARAM wparam, LPARAM lparam) noexcept {
  if (gpu_watchdog_ && gpu_watchdog_->HandleMessage(message, wparam)) {
    return 0;
  }

  // ... existing handling ...
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
```

## 4. Recover

The only recovery is restarting the process. The Windows embedder has no path that
recreates the display or contexts, so nothing done in-process brings the renderer back.

```cpp
void FlutterWindow::OnGraphicsContextLost() {
  // Release the view controller rather than destroying it. The renderer is already in a
  // bad state and a full teardown can block the quit path.
  (void)flutter_controller_.release();

  wchar_t path[MAX_PATH] = {};
  if (::GetModuleFileNameW(nullptr, path, MAX_PATH) != 0) {
    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi = {};
    if (::CreateProcessW(path, nullptr, nullptr, nullptr, FALSE, 0, nullptr,
                         nullptr, &si, &pi)) {
      ::CloseHandle(pi.hThread);
      ::CloseHandle(pi.hProcess);
    }
  }
  ::PostQuitMessage(0);
}
```

**This restart is deliberately minimal, and a real app should do more.** Two things it
gets wrong on purpose, to stay readable:

- **No restart limit.** If the GPU is still broken when the new process starts, it will
  lose the context again and relaunch again, forever. Pass a counter on the command line,
  and after a few rapid restarts back off for several minutes. Reset the counter once a
  process has been up long enough — a fault once a day should never accumulate into
  permanent deferral, only genuinely rapid ones should.
- **No window state.** The replacement starts with default placement. If the app was
  minimised or in the tray, pass that through too, or it will pop up in the user's face.

Also give the outgoing process a moment to exit before the new one takes any single-
instance lock, if you use one.

## 5. Build

The patched engine is **not** picked up automatically — `flutter build` uses the prebuilt
artifacts in `bin\cache\artifacts\engine\windows-x64` unless told otherwise:

```powershell
$env:HAVE_FLUTTER_CONTEXT_LOSS_API = "1"
flutter clean          # required after changing the variable - CMake caches it
flutter build windows --release `
  --local-engine-src-path C:\src\flutter\engine\src `
  --local-engine host_release `
  --local-engine-host host_release
```

Put the patched SDK's `bin` on `PATH` so it is the `flutter` that actually runs:
`--local-engine` replaces the engine, not the framework, and a framework from a different
SDK version is not guaranteed to match it.

## Verifying it worked

```powershell
dumpbin /imports build\windows\x64\runner\Release\<your_app>.exe | findstr GraphicsContextLost
```

Two imports means the detection is compiled in. No output means it is not — check
`HAVE_FLUTTER_CONTEXT_LOSS_API` and that the local-engine flags were passed.

## Testing without waiting for a driver crash

Disabling and re-enabling the display adapter in Device Manager produces a real
`EGL_CONTEXT_LOST`, and is the fastest way to exercise the whole path end to end.
