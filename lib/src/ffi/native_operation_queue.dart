import 'dart:async';

/// Orders calls that borrow one native handle, including its final destruction.
class NativeOperationQueue {
  Future<void> _tail = Future<void>.value();
  Future<void>? _closing;
  int _pending = 0;

  bool get isBusy => _pending != 0;
  bool get isClosed => _closing != null;

  Future<T> run<T>(Future<T> Function() operation) {
    if (isClosed) return Future<T>.error(StateError('Native handle is closed'));
    _pending++;
    final result = _tail
        .then((_) => operation())
        .whenComplete(() => _pending--);
    // A failed operation must neither poison cleanup nor hide its caller's error.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> close(Future<void> Function() release) {
    if (_closing case final closing?) return closing;
    _pending++;
    return _closing = _tail
        .then((_) => release())
        .whenComplete(() => _pending--);
  }
}
