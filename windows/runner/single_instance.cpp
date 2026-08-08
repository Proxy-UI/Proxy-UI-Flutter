#include "single_instance.h"

#include <sddl.h>

namespace single_instance {

namespace {

// Session-local rather than global: a window living in another desktop session
// cannot be raised, so one instance per session is the useful granularity.
constexpr wchar_t kMutexName[] = L"Local\\ProxyWithFlutter.SingleInstance";

// Marks the window that `ActivateRunningInstance` looks for. Window properties
// are readable across processes, which the window title and class name are too
// but neither of those is unique to this app.
constexpr wchar_t kWindowProperty[] = L"ProxyWithFlutter.MainWindow";

constexpr wchar_t kActivationMessageName[] =
    L"ProxyWithFlutter.ActivateMainWindow";

// SYSTEM, administrators and the interactive user get full access, and the
// object carries a low mandatory label. Without that label an unelevated launch
// could not open a lock created while the app runs elevated for TUN, and the
// two would happily run side by side.
constexpr wchar_t kMutexSecurity[] =
    L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;IU)S:(ML;;NW;;;LW)";

// Long enough for the outgoing instance to finish its own shutdown, short
// enough that a stuck process cannot hang the elevated relaunch forever.
constexpr DWORD kHandoffTimeoutMs = 10000;

// The running instance raises its window inside this call, so the timeout only
// has to cover a busy UI thread.
constexpr DWORD kActivationTimeoutMs = 3000;

HANDLE g_lock = nullptr;

BOOL CALLBACK FindMainWindow(HWND window, LPARAM lparam) {
  if (::GetPropW(window, kWindowProperty) == nullptr) {
    return TRUE;
  }
  *reinterpret_cast<HWND*>(lparam) = window;
  return FALSE;
}

HWND FindRunningMainWindow() {
  HWND window = nullptr;
  ::EnumWindows(FindMainWindow, reinterpret_cast<LPARAM>(&window));
  return window;
}

}  // namespace

UINT ActivationMessage() {
  static const UINT message = ::RegisterWindowMessageW(kActivationMessageName);
  return message;
}

LockResult AcquireLock(bool wait_for_handoff) {
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.bInheritHandle = FALSE;

  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (::ConvertStringSecurityDescriptorToSecurityDescriptorW(
          kMutexSecurity, SDDL_REVISION_1, &descriptor, nullptr)) {
    attributes.lpSecurityDescriptor = descriptor;
  }

  g_lock = ::CreateMutexW(descriptor != nullptr ? &attributes : nullptr, FALSE,
                          kMutexName);
  if (descriptor != nullptr) {
    ::LocalFree(descriptor);
  }

  // Fail open. Starting twice is a much smaller problem than an app that a
  // broken or hijacked lock object can stop from ever starting.
  if (g_lock == nullptr) {
    return LockResult::kPrimary;
  }

  const DWORD wait = ::WaitForSingleObject(
      g_lock, wait_for_handoff ? kHandoffTimeoutMs : 0);
  // WAIT_ABANDONED means the previous owner exited without releasing, which is
  // exactly what the elevated TUN handoff looks like from here.
  if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
    return LockResult::kPrimary;
  }

  ::CloseHandle(g_lock);
  g_lock = nullptr;
  return LockResult::kSecondary;
}

void ReleaseLock() {
  if (g_lock == nullptr) {
    return;
  }
  ::ReleaseMutex(g_lock);
  ::CloseHandle(g_lock);
  g_lock = nullptr;
}

void ActivateRunningInstance() {
  const UINT message = ActivationMessage();
  if (message == 0) {
    return;
  }

  const HWND window = FindRunningMainWindow();
  if (window != nullptr) {
    DWORD process_id = 0;
    ::GetWindowThreadProcessId(window, &process_id);
    if (process_id != 0) {
      // Hand our foreground rights over. Without this Windows only flashes the
      // other instance's taskbar button instead of raising it.
      ::AllowSetForegroundWindow(process_id);
    }
    // Sent, not posted: this process has to stay alive until the window is up,
    // because exiting first drops the foreground grant.
    ::SendMessageTimeoutW(window, message, 0, 0, SMTO_ABORTIFHUNG,
                          kActivationTimeoutMs, nullptr);
    return;
  }

  // The lock is held but no window is published yet, so the other instance is
  // still starting. Broadcasting reaches it once its window exists, and the
  // registered message id means no other application can misread it.
  ::AllowSetForegroundWindow(ASFW_ANY);
  ::PostMessageW(HWND_BROADCAST, message, 0, 0);
}

void RegisterMainWindow(HWND window) {
  ::SetPropW(window, kWindowProperty,
             reinterpret_cast<HANDLE>(static_cast<INT_PTR>(1)));

  const UINT message = ActivationMessage();
  if (message != 0) {
    // TUN keeps this process elevated, and UIPI would otherwise drop messages
    // sent by the unelevated launcher the user just double-clicked.
    ::ChangeWindowMessageFilterEx(window, message, MSGFLT_ALLOW, nullptr);
  }
}

void UnregisterMainWindow(HWND window) {
  ::RemovePropW(window, kWindowProperty);
}

void RaiseWindow(HWND window) {
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    // Undoes the close-to-tray hide. A no-op when the window is already up.
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetForegroundWindow(window);
}

}  // namespace single_instance
