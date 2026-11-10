import 'dart:async';

/// Shares concurrent attempts and retains successful completion. A failure is
/// surfaced, never retried automatically. Explicit retries keep the same mode.
/// The caller must retain the same already-prepared transaction, not regenerate.
class SubmissionGate<T> {
  Future<T>? _operation;
  String? _mode;
  Future<T> run(String mode, Future<T> Function() submit) {
    if (_mode != null && _mode != mode) {
      return Future.error(
        StateError('This prepared transaction already uses another submission mode.'),
      );
    }
    _mode = mode;
    final pending = _operation;
    if (pending != null) return pending;
    late final Future<T> operation;
    operation = Future<T>.sync(submit).then<T>(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        if (identical(_operation, operation)) _operation = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _operation = operation;
    return operation;
  }
}
