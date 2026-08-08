#ifndef RUNNER_NATIVE_CLEANUP_H_
#define RUNNER_NATIVE_CLEANUP_H_

// Machine state the app must hand back even when Dart never runs again.
//
// A logoff or shutdown gives the process very little time and no guarantee that
// the UI isolate is scheduled once more, so anything that outlives the process
// has to be undone from the window procedure.
namespace native_cleanup {

// Puts back a system proxy this app took over.
//
// Resolved from the proxy library the Dart side already loaded, so a build
// without that library simply does nothing.
void RestoreSystemProxy();

}  // namespace native_cleanup

#endif  // RUNNER_NATIVE_CLEANUP_H_
