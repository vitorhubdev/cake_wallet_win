import 'dart:async';

/// Serializes asynchronous work without letting one failure poison later work.
/// Each caller still receives its own error; [idle] is only a drain barrier.
class AsyncSerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> get idle => _tail;

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then<T>((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
