import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cw_core/node.dart';
import 'package:cw_core/monero_node_health.dart';
import 'package:cw_core/utils/proxy_wrapper.dart';
import 'package:cw_core/utils/tor/disabled.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => CakeTor.instance = CakeTorDisabled());
  const info = {
    'status': 'OK',
    'height': 100,
    'target_height': 100,
    'nettype': 'mainnet',
    'offline': false,
    'synchronized': true,
  };

  test('Node adapter diagnoses the configured path and preserves configuration', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['method'], 'get_info');
      request.response.write(jsonEncode({'result': info}));
      await request.response.close();
    });
    final node = Node(
      uri: '127.0.0.1:${server.port}',
      path: '/custom',
      type: WalletType.monero,
      useSSL: false,
    );
    final before = node.toMap();
    final result = await node.probeMoneroHealth(samples: 1);
    expect(result.ready, isTrue);
    expect(paths, ['/custom/json_rpc']);
    expect(node.toMap(), before);
  });

  test('diagnostic never persists an HTTP redirect or silently enables TLS', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      await r.drain<void>();
      r.response.statusCode = 301;
      r.response.headers.set('Location', 'https://invalid.invalid/');
      await r.response.close();
    });
    final node = Node(uri: '127.0.0.1:${server.port}', type: WalletType.monero, useSSL: false);
    expect((await node.probeMoneroHealth(samples: 1)).state, MoneroNodeState.redirect);
    expect(node.useSSL, isFalse);
  });

  test('digest authentication is used by the real Node adapter', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((r) async {
      await r.drain<void>();
      requests++;
      if (r.headers.value('Authorization') == null) {
        r.response.statusCode = 401;
        r.response.headers.set(
          'WWW-Authenticate',
          'Digest realm="ci", nonce="fixture", qop="auth"',
        );
      } else {
        expect(r.headers.value('Authorization'), contains('username="ci-user"'));
        expect(r.headers.value('Authorization'), isNot(contains('synthetic-password')));
        r.response.write(jsonEncode({'result': info}));
      }
      await r.response.close();
    });
    final node = Node(
      uri: '127.0.0.1:${server.port}',
      type: WalletType.monero,
      login: 'ci-user',
      password: 'synthetic-password',
      useSSL: false,
    );
    expect((await node.probeMoneroHealth(samples: 1)).ready, isTrue);
    expect(requests, 2);
    expect(node.toString(), isNot(contains('synthetic-password')));
    expect(node.toString(), isNot(contains('ci-user')));
  });

  test('an accepting local SOCKS port is not proof of a working daemon', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    server.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {}, onError: (Object _) {});
    });
    final node = Node(
      uri: 'unresolvable.invalid:18081',
      type: WalletType.monero,
      socksProxyAddress: '127.0.0.1:${server.port}',
    );
    expect(await node.requestMoneroNode(timeout: const Duration(milliseconds: 150)), isFalse);
  });

  test('edited credentials and transport invalidate old measurements', () {
    final node = Node(uri: 'localhost:18081', type: WalletType.monero);
    final initial = node.healthIdentity;
    expect(Node.fromMap(node.toMap()).healthIdentity, initial);
    node.password = 'synthetic';
    expect(node.healthIdentity, isNot(initial));
    final withPassword = node.healthIdentity;
    node.useSSL = true;
    expect(node.healthIdentity, isNot(withPassword));
  });
}
