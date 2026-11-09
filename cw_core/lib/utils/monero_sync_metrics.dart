import 'dart:collection';

/// Monotonic observed scan progress, not network bandwidth or a trust score.
class MoneroSyncMetrics {
  const MoneroSyncMetrics({
    this.blocksPerSecond,
    this.withoutProgress = Duration.zero,
    this.samples = 0,
  });
  final double? blocksPerSecond;
  final Duration withoutProgress;
  final int samples;
  bool get stalled => samples >= 2 && withoutProgress >= const Duration(seconds: 45);
}

class MoneroSyncRateTracker {
  final Queue<(int, int)> _history = Queue();
  int? _lastProgressAt;
  static const _windowUs = 30 * 1000000;
  static const _maximumGapUs = 30 * 1000000;
  void reset() {
    _history.clear();
    _lastProgressAt = null;
  }

  int get sampleCount => _history.length;

  MoneroSyncMetrics observe({required int height, required int monotonicMicroseconds}) {
    final time = monotonicMicroseconds;
    if (height < 0 || time < 0) {
      reset();
      return const MoneroSyncMetrics();
    }
    if (_history.isNotEmpty &&
        (time < _history.last.$1 ||
            time - _history.last.$1 > _maximumGapUs ||
            height < _history.last.$2))
      reset();
    if (_history.isEmpty || height > _history.last.$2) _lastProgressAt = time;
    if (_history.isNotEmpty && time == _history.last.$1) {
      _history.removeLast();
    }
    _history.add((time, height));
    while (_history.length > 30 || (_history.length > 2 && time - _history.first.$1 > _windowUs)) {
      _history.removeFirst();
    }
    final elapsed = time - _history.first.$1;
    final advanced = height - _history.first.$2;
    final rate = _history.length < 2 || elapsed < 3 * 1000000 ? null : advanced * 1000000 / elapsed;
    return MoneroSyncMetrics(
      blocksPerSecond: rate,
      withoutProgress: Duration(microseconds: time - (_lastProgressAt ?? time)),
      samples: _history.length,
    );
  }
}

/// Only repeated native failures invalidate a previously displayed sync state.
class MoneroNodeFailureTracker {
  int _failures = 0;
  bool _reported = false;
  bool observe({required bool available}) {
    if (available) {
      _failures = 0;
      _reported = false;
      return false;
    }
    _failures++;
    if (_failures < 3 || _reported) return false;
    _reported = true;
    return true;
  }
}
