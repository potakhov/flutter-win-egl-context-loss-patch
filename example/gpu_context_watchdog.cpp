#include "gpu_context_watchdog.h"

// Defined by the build when the Flutter engine carries the context-loss patch. The
// include is guarded as well as the calls: on a stock SDK the declarations are simply
// absent from flutter_windows.h, so referencing them would not compile.
#ifdef HAVE_FLUTTER_CONTEXT_LOSS_API
#include <flutter_windows.h>
#endif

namespace {

// Arbitrary. Change it if it collides with a timer the host window already owns - timer
// IDs are per-window, so only this window's other timers matter.
constexpr UINT_PTR kTimerId = 0xA71D;

// How long a lost context can go unnoticed if the engine's own notification is never
// delivered. In practice the notification arrives in milliseconds and this never fires.
constexpr UINT kPollIntervalMs = 1000;

// Registered rather than a fixed WM_USER/WM_APP constant. This message goes to the
// application's top-level window, which in a Flutter app also hosts the view controller's
// window-proc delegates and whatever every plugin registers there - so a hard-coded
// offset is only as safe as everyone else's choice of offset. RegisterWindowMessage
// returns a value in the 0xC000-0xFFFF range that Windows guarantees is unique
// system-wide for a given string.
//
// Returns 0 if registration fails. Callers must not compare an incoming message against
// 0: WM_NULL is 0, so an unguarded comparison would match unrelated traffic.
UINT RecoveryMessage() {
  static const UINT message =
      ::RegisterWindowMessageW(L"Flutter.GraphicsContextLost");
  return message;
}

}  // namespace

bool GpuContextWatchdog::IsSupported() {
#ifdef HAVE_FLUTTER_CONTEXT_LOSS_API
  return true;
#else
  return false;
#endif
}

GpuContextWatchdog::GpuContextWatchdog(HWND window,
                                       std::function<void()> on_context_lost)
    : window_(window), on_context_lost_(std::move(on_context_lost)) {
#ifdef HAVE_FLUTTER_CONTEXT_LOSS_API
  const UINT message = RecoveryMessage();
  if (message != 0) {
    // Registration order does not matter. If the context was already lost before this
    // call, the engine posts immediately rather than dropping the event.
    ::FlutterDesktopSetGraphicsContextLostNotification(window_, message);
  }
  ::SetTimer(window_, kTimerId, kPollIntervalMs, nullptr);
#endif
}

GpuContextWatchdog::~GpuContextWatchdog() {
#ifdef HAVE_FLUTTER_CONTEXT_LOSS_API
  ::KillTimer(window_, kTimerId);

  // The registration is process-wide state and would otherwise outlive this object,
  // leaving the engine posting to a window that no longer exists.
  ::FlutterDesktopSetGraphicsContextLostNotification(nullptr, 0);
#endif
}

bool GpuContextWatchdog::HandleMessage(UINT message, WPARAM wparam) {
#ifdef HAVE_FLUTTER_CONTEXT_LOSS_API
  const UINT recovery = RecoveryMessage();
  if (recovery != 0 && message == recovery) {
    Trigger();
    return true;
  }

  if (message == WM_TIMER && wparam == kTimerId) {
    if (::FlutterDesktopIsGraphicsContextLost()) {
      Trigger();
    }
    return true;
  }
#else
  (void)message;
  (void)wparam;
#endif
  return false;
}

void GpuContextWatchdog::Trigger() {
  // Both signals can fire for the same fault, so ignore everything after the first.
  if (fired_) {
    return;
  }
  fired_ = true;

  // The context stays lost for the rest of the process's life; without this every
  // remaining tick would report it again.
  ::KillTimer(window_, kTimerId);

  if (on_context_lost_) {
    on_context_lost_();
  }
}
