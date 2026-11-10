// Synthetic loopback tests. No wallet, external RPC or payment data is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cw_core/lib/utils/prefer_ipv6_connection.dart';

final passed = <String>[];
void check(bool value, String label) {
  if (!value) throw StateError(label);
  passed.add(label);
}

HttpClient client() => HttpClient()..connectionFactory = connectPreferIPv6;
Future<String> post(HttpClient client, Uri uri) async {
  final request = await client.postUrl(uri);
  request.write('synthetic-only');
  final response = await request.close();
  return response.transform(utf8.decoder).join();
}

Future<void> main(List<String> arguments) async {
  final ipv4 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ipv4.listen((request) async {
    await request.drain<void>();
    request.response.write(request.connectionInfo!.remoteAddress.address);
    await request.response.close();
  });
  var c = client();
  try {
    check(
      await post(c, Uri.parse('http://localhost:${ipv4.port}/')) == '127.0.0.1',
      'IPv4 fallback occurs before request transmission',
    );
  } finally {
    c.close(force: true);
    await ipv4.close(force: true);
  }

  final ipv6 = await HttpServer.bind(InternetAddress.loopbackIPv6, 0, v6Only: true);
  ipv6.listen((request) async {
    await request.drain<void>();
    request.response.write(request.connectionInfo!.remoteAddress.address);
    await request.response.close();
  });
  c = client();
  try {
    check(
      await post(c, Uri.parse('http://localhost:${ipv6.port}/')) == '::1',
      'Working native IPv6 is preferred',
    );
  } finally {
    c.close(force: true);
    await ipv6.close(force: true);
  }

  final delayed = Completer<List<InternetAddress>>();
  final task = await connectPreferIPv6(
    Uri.parse('http://dns-test.invalid:12345/'),
    null,
    null,
    lookup: (_) => delayed.future,
  );
  final cancelled = task.socket.then<bool>((socket) {
    socket.destroy();
    throw StateError('Cancelled DNS attempt connected');
  }, onError: (Object error) => error is SocketException);
  task.cancel();
  delayed.complete([InternetAddress.loopbackIPv4]);
  check(await cancelled == true, 'Cancellation during DNS cannot open a late socket');

  final silent = Completer<List<InternetAddress>>();
  final timedTask = await connectPreferIPv6(
    Uri.parse('http://dns-test.invalid:12345/'),
    null,
    null,
    lookup: (_) => silent.future,
    lookupTimeout: const Duration(milliseconds: 40),
  );
  var timedOut = false;
  try {
    await timedTask.socket;
  } on TimeoutException {
    timedOut = true;
  }
  check(timedOut, 'DNS wait has a finite deadline');
  timedTask.cancel();
  silent.complete([]);

  final dropped = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var received = 0;
  dropped.listen((request) async {
    received++;
    await request.drain<void>();
    final socket = await request.response.detachSocket(writeHeaders: false);
    socket.destroy();
  });
  c = client();
  var failed = false;
  try {
    await post(
      c,
      Uri.parse('http://localhost:${dropped.port}/'),
    ).timeout(const Duration(seconds: 3));
  } catch (_) {
    failed = true;
  } finally {
    c.close(force: true);
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  check(failed && received == 1, 'A POST accepted then disconnected is not replayed');
  await dropped.close(force: true);

  final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var slowReceived = 0;
  slow.listen((request) async {
    slowReceived++;
    await request.drain<void>();
  });
  c = client();
  timedOut = false;
  try {
    await post(
      c,
      Uri.parse('http://localhost:${slow.port}/'),
    ).timeout(const Duration(milliseconds: 100));
  } on TimeoutException {
    timedOut = true;
  } finally {
    c.close(force: true);
  }
  check(timedOut && slowReceived == 1, 'Response timeout has no duplicate POST');
  await slow.close(force: true);

  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  proxy.listen((request) async {
    await request.drain<void>();
    request.response.write(request.headers.value('host'));
    await request.response.close();
  });
  c = client()..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
  try {
    check(
      await post(c, Uri.parse('http://target.invalid/')) == 'target.invalid',
      'Explicit proxy destination is respected',
    );
  } finally {
    c.close(force: true);
    await proxy.close(force: true);
  }

  if (arguments.length != 2) throw ArgumentError('Provide a temporary TLS certificate and key');
  final serverContext = SecurityContext()
    ..useCertificateChain(arguments[0])
    ..usePrivateKey(arguments[1]);
  final tls = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverContext);
  tls.listen((request) async {
    await request.drain<void>();
    request.response.write('verified TLS');
    await request.response.close();
  });
  final trustedContext = SecurityContext()..setTrustedCertificates(arguments[0]);
  c = HttpClient(context: trustedContext)
    ..connectionFactory = (uri, proxyHost, proxyPort) =>
        connectPreferIPv6(uri, proxyHost, proxyPort, securityContext: trustedContext);
  try {
    check(
      await post(c, Uri.parse('https://localhost:${tls.port}/')) == 'verified TLS',
      'TLS verifies the original hostname after IP selection',
    );
  } finally {
    c.close(force: true);
    await tls.close(force: true);
  }

  final negativeTls = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverContext);
  var tlsRequests = 0;
  negativeTls.listen((request) async {
    tlsRequests++;
    request.response.write('unexpected');
    await request.response.close();
  }, onError: (Object _) {});
  var rejected = false;
  c = client();
  try {
    await post(c, Uri.parse('https://localhost:${negativeTls.port}/'));
  } on HandshakeException {
    rejected = true;
  } finally {
    c.close(force: true);
  }
  check(
    rejected && tlsRequests == 0,
    'An untrusted certificate is rejected before POST transmission',
  );
  rejected = false;
  c = HttpClient(context: trustedContext)
    ..connectionFactory = (uri, proxyHost, proxyPort) =>
        connectPreferIPv6(uri, proxyHost, proxyPort, securityContext: trustedContext);
  try {
    await post(c, Uri.parse('https://127.0.0.1:${negativeTls.port}/'));
  } on HandshakeException {
    rejected = true;
  } finally {
    c.close(force: true);
  }
  check(rejected && tlsRequests == 0, 'A trusted certificate for the wrong hostname is rejected');
  await negativeTls.close(force: true);

  print(
    jsonEncode({
      'status': 'passed',
      'checks': passed.length,
      'cases': passed,
      'externalRpcRequests': 0,
      'paymentsSubmitted': 0,
    }),
  );
}
