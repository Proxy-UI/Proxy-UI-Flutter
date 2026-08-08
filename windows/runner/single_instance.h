#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// Keeps one copy of the app per desktop session.
//
// A second launch does not start a process of its own: it hands the request to
// the instance that already holds the lock, which restores and focuses its
// window. Two instances would in any case fight over the local proxy port, the
// TUN adapter and the system proxy settings.
namespace single_instance {

// Outcome of the startup handshake.
enum class LockResult {
  // This process owns the lock and should start normally.
  kPrimary,
  // Another instance owns the lock. The caller must exit.
  kSecondary,
};

// Claims the session-wide application lock.
//
// `wait_for_handoff` blocks briefly instead of giving up immediately. The
// Windows TUN flow relaunches this executable elevated and only then lets the
// unelevated process exit, so that relaunch has to be able to take the lock
// over rather than being turned away by the instance it is replacing.
LockResult AcquireLock(bool wait_for_handoff);

// Releases the lock. Not required before process exit, where Windows drops the
// handle for us.
void ReleaseLock();

// Asks the instance that owns the lock to raise its window.
void ActivateRunningInstance();

// Publishes `window` as the window to raise, and allows an unelevated launcher
// to post to it while this process runs elevated for TUN.
void RegisterMainWindow(HWND window);

// Withdraws a window published by `RegisterMainWindow`.
void UnregisterMainWindow(HWND window);

// The message `ActivateRunningInstance` sends. Zero if registration failed.
UINT ActivationMessage();

// Makes `window` visible and foreground. Safe to call repeatedly.
void RaiseWindow(HWND window);

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_
