// Standalone deterministic tests: no daemon, credentials, funds or pub packages.
import 'dart:async';
import 'dart:convert';
import '../cw_core/lib/utils/async_serial_queue.dart';
import '../cw_monero/lib/api/sync_polling.dart';

int checks = 0;
void check(bool value, String name) {
  if (!value) throw StateError(name);
  checks++;
}
Future<void> turn() => Future<void>.delayed(Duration.zero);

Future<void> main() async {
  final queue = AsyncSerialQueue();
  final blocker = Completer<void>();
  final events = <String>[];
  var finished = false;
  final first = queue.run(() async {
    events.add('write-start');
    await blocker.future;
    events.add('write-end');
    events.add('backup');
  }).then((_) => finished = true);
  final second = queue.run(() async { events.add('second'); });
  await turn();
  check(!finished && events.join(',') == 'write-start', 'write is awaited and serialized');
  blocker.complete();
  await Future.wait([first, second]);
  check(events.join(',') == 'write-start,write-end,backup,second', 'backup follows completed write');
  var failed = false;
  try { await queue.run<void>(() async { throw StateError('disk failure'); }); }
  catch (_) { failed = true; }
  check(failed, 'explicit writer receives error');
  check(await queue.run(() async => 42) == 42, 'failure does not poison the queue');
  await queue.idle;
  check(true, 'drain barrier completes after failure');

  var clock = DateTime.utc(2026, 1, 1);
  final cache = NodeHeightCache(clock: () => clock);
  var loads = 0;
  final pending = Completer<int>();
  final requests = List.generate(50, (_) => cache.read(('wallet-A', 1), () { loads++; return pending.future; }));
  await turn();
  check(loads == 1, '50 callers share one native height request');
  pending.complete(1000);
  check((await Future.wait(requests)).every((v) => v == 1000), 'shared request returns identical height');
  check(await cache.read(('wallet-A', 1), () async { loads++; return 2000; }) == 1000 && loads == 1, 'fresh TTL suppresses native calls');
  clock = clock.add(const Duration(seconds: 10));
  check(await cache.read(('wallet-A', 1), () async { loads++; return 2000; }) == 2000 && loads == 2, 'expired TTL refreshes');
  clock = clock.subtract(const Duration(minutes: 1));
  check(await cache.read(('wallet-A', 1), () async => 2100) == 2100, 'clock rollback does not freeze cache');
  check(cache.peek(('wallet-B', 1)) == 0, 'wallet switch clears old height');
  check(await cache.read(('wallet-B', 1), () async => -1) == 0, 'negative daemon height rejected');
  check(await cache.read(('wallet-B', 2), () async => 500) == 500, 'node generation clears old height');
  check(await cache.read(('wallet-B', 3), () => throw StateError('offline')) == 0, 'failure never reuses a synced height');
  final old = Completer<int>();
  final newer = Completer<int>();
  final oldRead = cache.read(('wallet-C', 1), () => old.future);
  final newRead = cache.read(('wallet-D', 1), () => newer.future);
  old.complete(999999);
  check(await oldRead == 0 && cache.peek(('wallet-D', 1)) == 0, 'late session result rejected');
  var duplicate = false;
  final joined = cache.read(('wallet-D', 1), () async { duplicate = true; return 1; });
  newer.complete(42);
  check(await joined == 42 && await newRead == 42 && !duplicate, 'old completion cannot clear new in-flight request');
  final aba = Completer<int>();
  final oldA = cache.read(('wallet-A', 1), () => aba.future);
  cache.peek(('wallet-B', 1));
  check(await cache.read(('wallet-A', 1), () async => 77) == 77, 'A-B-A starts a new cache generation');
  aba.complete(88);
  check(await oldA == 0 && cache.peek(('wallet-A', 1)) == 77, 'A-B-A ignores first generation completion');

  var active = true;
  var readCount = 0;
  var delivered = 0;
  var errors = 0;
  final blockedRead = Completer<int>();
  final poller = SessionPoller<int>(
    read: () { readCount++; return blockedRead.future; },
    onData: (_) => delivered++, isActive: () => active,
    onError: (_, __) => errors++,
  );
  final firstPoll = poller.poll();
  await Future.wait(List.generate(20, (_) => poller.poll()));
  check(readCount == 1, 'timer ticks cannot overlap slow I/O');
  poller.stop();
  blockedRead.complete(1);
  await firstPoll;
  await poller.poll();
  check(delivered == 0 && readCount == 1, 'stopped poller ignores pending result and future ticks');
  var attempts = 0;
  final recoverable = SessionPoller<int>(
    read: () async { if (attempts++ == 0) throw StateError('offline'); return 2; },
    onData: (_) => delivered++, isActive: () => active,
    onError: (_, __) => errors++,
  );
  await recoverable.poll();
  await recoverable.poll();
  check(errors == 1 && delivered == 1, 'poller recovers from I/O failure');
  recoverable.stop();
  final late = Completer<int>();
  final stale = SessionPoller<int>(read: () => late.future,
    onData: (_) => delivered++, isActive: () => active, onError: (_, __) => errors++);
  final stalePoll = stale.poll();
  active = false;
  late.complete(3);
  await stalePoll;
  check(delivered == 1, 'wallet switch ignores a pending poll');
  stale.stop();
  check(!isMoneroSyncComplete(99, true), '99 blocks remaining is not synchronized');
  check(!isMoneroSyncComplete(1, true), 'one block remaining is not synchronized');
  check(!isMoneroSyncComplete(0, false), 'native synchronization acknowledgement is required');
  check(!isMoneroSyncComplete(-1, true), 'invalid progress is not synchronized');
  check(isMoneroSyncComplete(0, true), 'zero remaining plus native acknowledgement is synchronized');
  print(jsonEncode({'status': 'passed', 'checks': checks, 'networkOperations': false}));
}
