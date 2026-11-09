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
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
    });
    await expectLater(
      ProxyWrapper().post(
        clearnetUri: Uri.parse('http://localhost:${server.port}/'),
        body: 'synthetic-only',
        preferIPv6: true,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<Exception>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 1);
  });

  test('POST timeout is preserved when IPv6 preference is enabled', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      // Deliberately no response; the request owner must close the client.
    });
    await expectLater(
      ProxyWrapper().post(
        clearnetUri: Uri.parse('http://localhost:${server.port}/'),
        body: 'synthetic-only',
        preferIPv6: true,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(requests, 1);
  });
}
