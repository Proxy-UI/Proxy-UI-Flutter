#ifndef RUNNER_STARTUP_LAUNCH_H_
#define RUNNER_STARTUP_LAUNCH_H_

// Opt-in "start when I sign in" support.
//
// Backed by the per-user Run key, which needs no elevation and matches how the
// app is installed (a plain Inno Setup / portable build rather than a packaged
// app with a manifest-declared startup task).
namespace startup_launch {

// Whether a sign-in entry for this app exists.
bool IsEnabled();

// Adds or removes the sign-in entry. Enabling always rewrites the recorded
// path, so an app that moved between installs points at itself again. Returns
// false when the registry rejected the change.
bool SetEnabled(bool enabled);

}  // namespace startup_launch

#endif  // RUNNER_STARTUP_LAUNCH_H_
