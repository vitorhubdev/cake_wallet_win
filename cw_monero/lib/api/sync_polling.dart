import 'dart:async';

/// One poll at a time, with a second session check after asynchronous I/O.
/// Stopping a timer does not cancel a running Future: its result must be ignored.
class SessionPoller<T> {
  SessionPoller({
    required this.read,
    required this.onData,
    required this.isActive,
    required this.onError,
    this.interval = const Duration(milliseconds: 1200),
  });

  final Future<T> Function() read;
  final void Function(T) onData;
  final bool Function() isActive;
  final void Function(Object, StackTrace) onError;
  final Duration interval;
  Timer? _timer;
  bool _busy = false;
  bool _stopped = false;

  void start() {
    if (_stopped) throw StateError('A stopped poller cannot be restarted.');
    _timer ??= Timer.periodic(interval, (_) => unawaited(poll()));
  }

  Future<void> poll() async {
    if (_stopped || _busy || !isActive()) return;
    _busy = true;
    try {
      final result = await read();
      if (!_stopped && isActive()) onData(result);
    } catch (error, stack) {
      if (!_stopped && isActive()) onError(error, stack);
    } finally {
      _busy = false;
    }
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// Cache keys include both wallet identity and node generation. Old requests
/// cannot overwrite a new session; expired data is never labelled as fresh.
class NodeHeightCache {
  NodeHeightCache({
    this.ttl = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  Object? _session;
  int _generation = 0;
  int _height = 0;
  DateTime? _checkedAt;
  Future<int>? _inFlight;

  void _select(Object session) {
    if (_session == session) return;
    _session = session;
    _generation++;
    _height = 0;
    _checkedAt = null;
    _inFlight = null;
  }

  int peek(Object session) {
    _select(session);
    return _height;
  }

  Future<int> read(Object session, Future<int> Function() load) {
    _select(session);
    final pending = _inFlight;
    if (pending != null) return pending;
    final now = _clock();
    final checked = _checkedAt;
    if (checked != null && !now.isBefore(checked) && now.difference(checked) < ttl) {
      return Future<int>.value(_height);
    }
    final generation = _generation;
    final result = Future<int>.sync(load).then((height) {
      if (generation != _generation) return 0;
      _height = height > 0 ? height : 0;
      _checkedAt = _clock();
      return _height;
    }, onError: (Object _, StackTrace __) {
      if (generation != _generation) return 0;
      // A failed/offline daemon is not evidence that the wallet is up to date.
      _height = 0;
      _checkedAt = _clock();
      return 0;
    }).whenComplete(() {
      if (generation == _generation) _inFlight = null;
    });
    _inFlight = result;
    return result;
  }
}

bool isMoneroSyncComplete(int blocksLeft, bool nativeSynchronized) =>
    blocksLeft == 0 && nativeSynchronized;
