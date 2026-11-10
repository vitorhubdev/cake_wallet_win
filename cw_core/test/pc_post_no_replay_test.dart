import 'dart:async';
import 'dart:io';

import 'package:cw_core/utils/proxy_wrapper.dart';
import 'package:cw_core/utils/tor/disabled.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => CakeTor.instance = CakeTorDisabled());

  test('POST response failure never retries with another address family', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestSeen = Completer<void>();
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (!requestSeen.isCompleted) requestSeen.complete();
      await request.drain<void>();
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
    });

    // The hostname deliberately exercises IPv6-to-IPv4 fallback BEFORE the
    // HTTP request is sent. On Windows DNS and connection setup may consume
    // more than two seconds even for localhost; a timeout there tests nothing
    // about whether a POST was replayed after receiving a broken response.
    await expectLater(
      ProxyWrapper().post(
        clearnetUri: Uri.parse('http://localhost:${server.port}/'),
        body: 'synthetic-only',
        preferIPv6: true,
        timeout: const Duration(seconds: 12),
      ),
      throwsA(isA<Exception>()),
    );
    await requestSeen.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw StateError(
        'The server never received the POST; connection setup failed before the response-replay assertion.',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(requests, 1, reason: 'A failed POST response must never trigger a second request.');
  });

  test('POST timeout is preserved when IPv6 preference is enabled', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestSeen = Completer<void>();
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (!requestSeen.isCompleted) requestSeen.complete();
      await request.drain<void>();
      // Deliberately no response; the request owner must close the client.
    });

    // Use an explicit loopback IP here: this test is about the response
    // deadline, not address-family discovery. The separate IPv6 fallback test
    // uses localhost and verifies that the selected family is correct.
    await expectLater(
      ProxyWrapper().post(
        clearnetUri: Uri.parse('http://127.0.0.1:${server.port}/'),
        body: 'synthetic-only',
        preferIPv6: true,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await requestSeen.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw StateError(
        'The server never received the POST; this did not test an in-flight HTTP timeout.',
      ),
    );
    expect(requests, 1, reason: 'A timed-out POST must not be replayed.');
  });
}
