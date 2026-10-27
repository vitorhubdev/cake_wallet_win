import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cw_core/node.dart';
import 'package:cw_core/utils/proxy_wrapper.dart';
import 'package:cw_core/utils/tor/disabled.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';

// Real loopback sockets prove that a timed-out probe closes its connection.
// No external node, wallet, seed, API credential, or funds are involved.
void main() {
  setUp(() => CakeTor.instance = CakeTorDisabled());

  test('a completed POST retains its response and closes its owned connection', () async {
    final endpoint = await _LocalEndpoint.start((request, socket) {
      _respond(socket, 200, '{"result":{"offline":false}}');
    });
    addTearDown(endpoint.dispose);

    final response = await ProxyWrapper().post(clearnetUri: endpoint.uri, body: '{}');
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body)['result']['offline'], isFalse);
    await endpoint.waitForClosedConnections();
    expect(endpoint.requests, hasLength(1));
  });

  test('a POST deadline aborts the socket while a node withholds its response', () async {
    final endpoint = await _LocalEndpoint.start((request, socket) {});
    addTearDown(endpoint.dispose);

    await expectLater(
      ProxyWrapper().post(
        clearnetUri: endpoint.uri,
        body: '{}',
        timeout: const Duration(seconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(endpoint.requests, hasLength(1));
    await endpoint.waitForClosedConnections();
  });

  test('Monero reports an unresponsive node without retaining its socket', () async {
    final endpoint = await _LocalEndpoint.start((request, socket) {});
    addTearDown(endpoint.dispose);
    final node = Node(
      uri: '${endpoint.uri.host}:${endpoint.uri.port}',
      type: WalletType.monero,
      useSSL: false,
    );

    expect(await node.requestMoneroNode(timeout: const Duration(seconds: 1)), isFalse);
    expect(endpoint.requests, hasLength(1));
    await endpoint.waitForClosedConnections();
  });

  test('digest RPC completes authentication and closes its shared client', () async {
    final endpoint = await _LocalEndpoint.start((request, socket) {
      if (!request.toLowerCase().contains('\r\nauthorization: digest ')) {
        _respond(
          socket,
          401,
          '',
          headers: {'WWW-Authenticate': 'Digest realm="ci", nonce="local-test", qop="auth"'},
        );
      } else {
        _respond(socket, 200, '{"result":{"offline":false}}');
      }
    });
    addTearDown(endpoint.dispose);

    final response = await DaemonRpc(
      endpoint.uri.toString(),
      username: 'synthetic-test-user',
      password: 'synthetic-test-password',
    ).call('get_info', {});
    expect(response['offline'], isFalse);
    expect(endpoint.requests, hasLength(2));
    await endpoint.waitForClosedConnections();
  });

  test('digest RPC closes the connection if the authenticated response stalls', () async {
    final endpoint = await _LocalEndpoint.start((request, socket) {
      if (!request.toLowerCase().contains('\r\nauthorization: digest ')) {
        _respond(
          socket,
          401,
          '',
          headers: {'WWW-Authenticate': 'Digest realm="ci", nonce="local-test", qop="auth"'},
        );
      }
    });
    addTearDown(endpoint.dispose);

    await expectLater(
      DaemonRpc(
        endpoint.uri.toString(),
        username: 'synthetic-test-user',
        password: 'synthetic-test-password',
      ).call('get_info', {}, timeout: const Duration(seconds: 1)),
      throwsA(isA<TimeoutException>()),
    );
    expect(endpoint.requests, hasLength(2));
    await endpoint.waitForClosedConnections();
  });
}

void _respond(Socket socket, int status, String body, {Map<String, String> headers = const {}}) {
  final bytes = utf8.encode(body);
  final head = StringBuffer('HTTP/1.1 $status ${status == 200 ? 'OK' : 'Unauthorized'}\r\n')
    ..write('Content-Length: ${bytes.length}\r\n')
    ..write('Content-Type: application/json\r\n')
    ..write('Connection: keep-alive\r\n');
  headers.forEach((name, value) => head.write('$name: $value\r\n'));
  head.write('\r\n');
  socket.add(utf8.encode(head.toString()));
  socket.add(bytes);
}

class _LocalEndpoint {
  _LocalEndpoint(this._server, this._handler) {
    _idle.complete();
    _server.listen(_accept);
  }

  static Future<_LocalEndpoint> start(void Function(String, Socket) handler) async =>
      _LocalEndpoint(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), handler);

  final ServerSocket _server;
  final void Function(String, Socket) _handler;
  final Set<Socket> _connections = {};
  final List<String> requests = [];
  Completer<void> _idle = Completer<void>();

  Uri get uri =>
      Uri(scheme: 'http', host: _server.address.address, port: _server.port, path: '/json_rpc');

  void _accept(Socket socket) {
    if (_connections.isEmpty) _idle = Completer<void>();
    _connections.add(socket);
    var pending = '';
    void closed() {
      _connections.remove(socket);
      socket.destroy();
      if (_connections.isEmpty && !_idle.isCompleted) _idle.complete();
    }

    socket.listen(
      (data) {
        pending += String.fromCharCodes(data);
        while (true) {
          final headerEnd = pending.indexOf('\r\n\r\n');
          if (headerEnd < 0) return;
          final contentLength = RegExp(
            r'content-length:\s*(\d+)',
            caseSensitive: false,
          ).firstMatch(pending.substring(0, headerEnd));
          final end = headerEnd + 4 + int.parse(contentLength?.group(1) ?? '0');
          if (pending.length < end) return;
          final request = pending.substring(0, end);
          pending = pending.substring(end);
          requests.add(request);
          _handler(request, socket);
        }
      },
      onDone: closed,
      onError: (Object error) => closed(),
      cancelOnError: true,
    );
  }

  Future<void> waitForClosedConnections() => _idle.future.timeout(const Duration(seconds: 3));

  Future<void> dispose() async {
    for (final socket in _connections.toList()) {
      socket.destroy();
    }
    await _server.close();
  }
}
