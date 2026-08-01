#ifndef GPU_CONTEXT_WATCHDOG_H_
#define GPU_CONTEXT_WATCHDOG_H_

#include <windows.h>

#include <functional>

// Reports a permanently lost graphics context, once, on the platform thread.
//
// Requires a Flutter engine carrying the context-loss patch. Without it the class still
// compiles and is inert, so the same source builds against a stock SDK - see
// HAVE_FLUTTER_CONTEXT_LOSS_API below and IsSupported().
//
// Two independent signals feed it, deliberately:
//
//   * the engine posts a window message the instant the loss is observed. This is the
//     fast path - single-digit milliseconds from driver fault to callback.
//   * a one-second timer polls FlutterDesktopIsGraphicsContextLost(). This is the
//     guarantee. PostMessage can fail, and a lost context is the one failure a host
//     cannot otherwise discover, so the poll bounds the worst case instead of leaving it
//     unbounded.
//
// The callback runs at most once. Recovery means restarting the process: the Windows
// embedder has no path that recreates the display or contexts, so nothing an app does
// in-process will bring the renderer back.
class GpuContextWatchdog {
 public:
  // |window| must have a running message loop and must outlive this object; the watchdog
  // owns a timer on it and receives its notification there.
  //
  // |on_context_lost| runs on the platform thread, from inside |HandleMessage|. It must
  // not synchronously destroy this object or |window|. Post a message and act on it
  // afterwards if teardown is needed.
  GpuContextWatchdog(HWND window, std::function<void()> on_context_lost);
  ~GpuContextWatchdog();

  GpuContextWatchdog(const GpuContextWatchdog&) = delete;
  GpuContextWatchdog& operator=(const GpuContextWatchdog&) = delete;

  // Call from the window procedure before anything else handles the message. Returns true
  // when the message belonged to this watchdog and needs no further handling.
  bool HandleMessage(UINT message, WPARAM wparam);

  // Whether this build can detect anything at all. False when compiled without the
  // patched engine - worth surfacing in a log at startup, because a build that cannot
  // notice the failure it exists for should not be silent about it.
  static bool IsSupported();

 private:
  void Trigger();

  HWND window_ = nullptr;
  std::function<void()> on_context_lost_;
  bool fired_ = false;
};

#endif  // GPU_CONTEXT_WATCHDOG_H_
