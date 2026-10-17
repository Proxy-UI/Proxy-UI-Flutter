import 'dart:async';

/// Complete cleanup before the Windows replacement's single-instance wait
/// expires. Keep two seconds of headroom below kHandoffTimeoutMs (10 seconds)
/// in windows/runner/single_instance.cpp. Call immediately after launch succeeds.
///
/// Time out each awaited step, not the entire workflow: a late completion must
/// never continue to the next step and ultimately exit after the child gave up.
Future<bool> prepareElevationExit({
  required Future<bool> Function() stopProxy,
  required Future<void> Function() releaseTray,
  required Future<void> Function() flushLogs,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final clock = Stopwatch()..start();
  Future<T> wait<T>(Future<T> Function() action) {
    final remaining = timeout - clock.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Windows elevation cleanup deadline exceeded');
    }
    return action().timeout(remaining);
  }

  if (!await wait(stopProxy)) return false;
  await wait(releaseTray);
  await wait(flushLogs);
  if (clock.elapsed >= timeout) {
    throw TimeoutException('Windows elevation cleanup deadline exceeded');
  }
  return true;
}
