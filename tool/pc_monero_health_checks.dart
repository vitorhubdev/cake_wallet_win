// Real loopback HTTP/TLS and deterministic metrics. No keys, wallets or payments.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cw_core/lib/monero_node_health.dart';
import '../cw_core/lib/utils/monero_sync_metrics.dart';
import '../cw_core/lib/utils/submission_gate.dart';
import '../cw_core/lib/utils/async_serial_queue.dart';

int checks = 0;
void check(bool condition, String message) {
  if (!condition) throw StateError(message);
  checks++;
}

const ready = <String, Object>{
  'status': 'OK',
  'height': 100,
  'target_height': 100,
  'nettype': 'mainnet',
  'offline': false,
  'synchronized': true,
  'busy_syncing': false,
};

Future<void> main(List<String> arguments) async {
  for (final entry in <(Map<String, dynamic>, MoneroNodeState)>[
    (ready, MoneroNodeState.ready),
    ({...ready, 'nettype': 'testnet'}, MoneroNodeState.wrongNetwork),
    ({...ready, 'testnet': true}, MoneroNodeState.wrongNetwork),
    ({...ready, 'offline': true}, MoneroNodeState.offline),
    ({...ready, 'synchronized': false}, MoneroNodeState.syncing),
    ({...ready, 'busy_syncing': true}, MoneroNodeState.syncing),
    ({...ready, 'target_height': 101}, MoneroNodeState.syncing),
    ({...ready, 'height': 0}, MoneroNodeState.syncing),
    ({...ready, 'height': '100'}, MoneroNodeState.invalidResponse),
    ({...ready, 'height': -1}, MoneroNodeState.invalidResponse),
    ({...ready, 'status': 'BUSY'}, MoneroNodeState.syncing),
    ({...ready, 'status': 'FAILED'}, MoneroNodeState.rpcError),
    ({'status': 'OK', 'height': 100}, MoneroNodeState.unknownReadiness),
    ({...ready, 'synchronized': null}, MoneroNodeState.unknownReadiness),
  ]) {
    check(classifyMoneroNode(entry.$1) == entry.$2, 'get_info state ${entry.$2}');
  }
  final now = DateTime.utc(2026, 11, 9);
  check(parseMoneroRetryAfter('60', now) == const Duration(minutes: 1), 'seconds Retry-After');
  check(
    parseMoneroRetryAfter(HttpDate.format(now.add(const Duration(seconds: 60))), now) ==
        const Duration(minutes: 1),
    'HTTP date Retry-After',
  );
  check(parseMoneroRetryAfter('-3', now) == null, 'negative cooldown rejected');
  check(parseMoneroRetryAfter('999999', now) == const Duration(days: 1), 'cooldown bounded');
  check(parseMoneroRetryAfter('not-a-date', now) == null, 'bad cooldown rejected');

  var factoryCalls = 0;
  final blocked = await probeMoneroNode(
    endpoint: Uri.parse('http://example.onion/json_rpc'),
    createClient: () {
      factoryCalls++;
      return HttpClient();
    },
  );
  check(
    blocked.state == MoneroNodeState.proxyUnavailable && factoryCalls == 0,
    'Onion without proxy never starts direct DNS/TCP',
  );
  final invalid = await probeMoneroNode(
    endpoint: Uri.parse('https://user:secret@localhost/json_rpc'),
    createClient: () {
      factoryCalls++;
      return HttpClient();
    },
  );
  check(
    invalid.state == MoneroNodeState.invalidConfig && factoryCalls == 0,
    'Embedded credentials are not accepted or logged',
  );

  Future<MoneroNodeHealth> http(
    void Function(HttpRequest, int) handler, {
    int samples = 1,
    MoneroDigestHeader? digest,
    Duration timeout = const Duration(seconds: 2),
    MoneroProbeCancellation? cancellation,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      await request.drain<void>();
      handler(request, ++requests);
    }, onError: (Object _) {});
    try {
      return await probeMoneroNode(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/json_rpc'),
        createClient: HttpClient.new,
        samples: samples,
        timeout: timeout,
        digestHeader: digest,
        cancellation: cancellation,
      );
    } finally {
      await server.close(force: true);
    }
  }

  void jsonResponse(HttpRequest request, Map<String, Object?> data) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    unawaited(request.response.close().catchError((_) {}));
  }

  final good = await http((r, _) {
    check(
      r.contentLength > 0 && r.headers.value(HttpHeaders.transferEncodingHeader) == null,
      'Monero metadata uses Content-Length, not unsupported chunked requests',
    );
    jsonResponse(r, {'result': ready});
  }, samples: 3);
  check(
    good.ready && good.samples == 3 && good.latencyMs! >= 1 && good.jitterMs! >= 0,
    'Three actual bounded RPC samples produce median and jitter',
  );
  for (final entry in <int, MoneroNodeState>{
    401: MoneroNodeState.authenticationRequired,
    403: MoneroNodeState.forbidden,
    451: MoneroNodeState.forbidden,
    429: MoneroNodeState.rateLimited,
    503: MoneroNodeState.serverError,
    404: MoneroNodeState.rpcError,
    302: MoneroNodeState.redirect,
  }.entries) {
    var received = 0;
    final result = await http((r, n) {
      received = n;
      r.response.statusCode = entry.key;
      r.response.headers.set('Retry-After', '90');
      if (entry.key == 302) r.response.headers.set('Location', 'http://invalid.invalid/');
      unawaited(r.response.close());
    }, samples: 3);
    check(
      result.state == entry.value && result.httpStatus == entry.key && received == 1,
      'HTTP ${entry.key} classified without retries or redirects',
    );
    if (entry.key == 429)
      check(result.retryAfter == const Duration(seconds: 90), '429 cooldown retained');
  }
  var authRequests = 0;
  final auth = await http(
    (r, n) {
      authRequests = n;
      if (n == 1) {
        r.response.statusCode = 401;
        r.response.headers.set(
          'WWW-Authenticate',
          'Digest realm="ci", nonce="synthetic", qop="auth"',
        );
        unawaited(r.response.close());
      } else {
        check(
          r.headers.value('Authorization') == 'Digest synthetic-test',
          'Auth used only after challenge',
        );
        jsonResponse(r, {'result': ready});
      }
    },
    digest: (challenge, method, path) {
      check(method == 'POST' && path == '/json_rpc', 'Auth digest binds method/path');
      return 'Digest synthetic-test';
    },
  );
  check(auth.ready && authRequests == 2, 'Authenticated read finishes without extra replay');
  final huge = await http((r, _) {
    r.response.write('x' * 65537);
    unawaited(r.response.close().catchError((_) {}));
  });
  check(huge.state == MoneroNodeState.invalidResponse, 'Response size is capped');
  final malformed = await http((r, _) {
    r.response.write('<html>refused</html>');
    unawaited(r.response.close());
  });
  check(malformed.state == MoneroNodeState.invalidResponse, 'HTML cannot be marked healthy');
  final rpcError = await http(
    (r, _) => jsonResponse(r, {
      'error': {'message': 'synthetic sensitive text'},
    }),
  );
  check(rpcError.state == MoneroNodeState.invalidResponse, 'RPC error body is not shown');
  final timeout = await http((r, _) {}, timeout: const Duration(milliseconds: 100));
  check(timeout.state == MoneroNodeState.timeout, 'Stalled response has bounded timeout');
  final cancellation = MoneroProbeCancellation();
  final cancelled = await http((r, _) {
    cancellation.cancel();
  }, cancellation: cancellation);
  check(!cancelled.ready, 'Cancelling the probe aborts the connection');
  final lateFactory = Completer<HttpClient>();
  final deadline = await probeMoneroNode(
    endpoint: Uri.parse('http://127.0.0.1:1/json_rpc'),
    createClient: () => lateFactory.future,
    timeout: const Duration(milliseconds: 30),
  );
  lateFactory.complete(HttpClient());
  await Future<void>.delayed(const Duration(milliseconds: 30));
  check(deadline.state == MoneroNodeState.timeout, 'Late client creation is cancelled and closed');

  final unbound = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = unbound.port;
  await unbound.close();
  final refused = await probeMoneroNode(
    endpoint: Uri.parse('http://127.0.0.1:$port/json_rpc'),
    createClient: HttpClient.new,
    samples: 1,
  );
  check(
    refused.state == MoneroNodeState.connectionRefused,
    'Refused TCP classified without claiming an IP ban: ${refused.state}',
  );
  if (arguments.length == 2) {
    final context = SecurityContext()
      ..useCertificateChain(arguments[0])
      ..usePrivateKey(arguments[1]);
    final tls = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    tls.listen((r) => jsonResponse(r, {'result': ready}), onError: (Object _) {});
    try {
      final rejected = await probeMoneroNode(
        endpoint: Uri.parse('https://localhost:${tls.port}/json_rpc'),
        createClient: () => HttpClient()..badCertificateCallback = (_, __, ___) => true,
        samples: 1,
      );
      check(
        rejected.state == MoneroNodeState.tlsError,
        'Diagnostic enforces certificate validation',
      );
    } finally {
      await tls.close(force: true);
    }
  }

  final tracker = MoneroSyncRateTracker();
  check(
    tracker.observe(height: 10, monotonicMicroseconds: 0).blocksPerSecond == null,
    'No invented first-sample speed',
  );
  check(
    tracker.observe(height: 20, monotonicMicroseconds: 1000000).blocksPerSecond == null,
    'Warmup before speed',
  );
  check(
    tracker.observe(height: 50, monotonicMicroseconds: 4000000).blocksPerSecond == 10,
    'Speed uses scan height and monotonic time',
  );
  check(
    tracker.observe(height: 5, monotonicMicroseconds: 5000000).blocksPerSecond == null,
    'Height rollback resets old rate',
  );
  check(
    tracker.observe(height: 10, monotonicMicroseconds: 40000000).blocksPerSecond == null,
    'Resume gap resets rate',
  );
  for (var i = 1; i <= 100; i++) {
    tracker.observe(height: 10, monotonicMicroseconds: 40000000 + i * 1000000);
  }
  final stagnant = tracker.observe(height: 10, monotonicMicroseconds: 141000000);
  check(
    stagnant.blocksPerSecond == 0 && stagnant.stalled,
    'No advance reports zero, not stale positive speed',
  );
  check(tracker.sampleCount <= 30, 'Rate history has bounded memory');
  tracker.reset();
  check(
    tracker.observe(height: 300, monotonicMicroseconds: 142000000).blocksPerSecond == null,
    'Node/wallet reset clears prior session',
  );
  final failures = MoneroNodeFailureTracker();
  check(!failures.observe(available: false), 'One failed native poll is not a disconnect');
  check(!failures.observe(available: false), 'Two failed polls tolerate a transient outage');
  check(failures.observe(available: false), 'Third failed poll invalidates stale synced state');
  check(!failures.observe(available: false), 'Disconnect is reported once');
  check(!failures.observe(available: true), 'Healthy poll resets failure history');
  check(!failures.observe(available: false), 'New failure is not inherited');
  final gate = SubmissionGate<int>();
  final answer = Completer<int>();
  var sends = 0;
  final attempts = List.generate(
    50,
    (_) => gate.run('broadcast', () {
      sends++;
      return answer.future;
    }),
  );
  check(sends == 1, 'Fifty concurrent confirmations share one submission');
  answer.complete(42);
  check(
    (await Future.wait(attempts)).every((value) => value == 42),
    'All confirmation callers observe the same result',
  );
  check(
    await gate.run('broadcast', () async {
              sends++;
              return 0;
            }) ==
            42 &&
        sends == 1,
    'A confirmed submission is never repeated by the same object',
  );
  var modeRejected = false;
  try {
    await gate.run('ur', () async => 1);
  } on StateError {
    modeRejected = true;
  }
  check(modeRejected, 'UR export and normal broadcast cannot race the same prepared object');
  final retry = SubmissionGate<int>();
  var retried = 0;
  try {
    await retry.run('broadcast', () {
      retried++;
      throw StateError('synthetic failure');
    });
  } on StateError {}
  await Future<void>.delayed(Duration.zero);
  check(retried == 1, 'Submission failure does not trigger an automatic retry');
  check(
    await retry.run('broadcast', () async {
              retried++;
              return 9;
            }) ==
            9 &&
        retried == 2,
    'A failed submission permits only a new explicit attempt',
  );
  final queue = AsyncSerialQueue();
  final native = Completer<void>();
  var closed = false;
  final submitted = queue.run(() => native.future);
  final closeBarrier = queue.idle.then((_) {
    closed = true;
  });
  await Future<void>.delayed(Duration.zero);
  check(!closed, 'Shared native queue keeps closure behind an in-flight submission');
  native.complete();
  await submitted;
  await closeBarrier;
  check(closed, 'Native closure barrier completes after submission');

  print(
    jsonEncode({
      'status': 'passed',
      'checks': checks,
      'publicNodeRequests': 0,
      'paymentsSubmitted': 0,
    }),
  );
}
