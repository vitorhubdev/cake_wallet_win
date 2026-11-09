// Exercises the actual pinned SOCKS adapter with loopback servers, not wallets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../cw_core/lib/monero_node_health.dart';
import '../cw_core/lib/utils/monero_probe_transport.dart';
import '../cw_core/lib/utils/monero_probe_request.dart';

int checks = 0;
void check(bool condition, String message) {
  if (!condition) throw StateError(message);
  checks++;
}

class LocalSocks {
  LocalSocks(
    this.server, {
    this.holdGreeting = false,
    this.holdTarget = false,
    this.reject = 0,
    this.tunnelPort,
  }) {
    server.listen(accept);
  }
  final ServerSocket server;
  final bool holdGreeting;
  final bool holdTarget;
  final int reject;
  final int? tunnelPort;
  final Set<Socket> connections = {};
  final List<String> targets = [];
  final List<String> requests = [];
  final Set<Socket> remotes = {};
  String get endpoint => '127.0.0.1:${server.port}';
  static Future<LocalSocks> start({
    bool holdGreeting = false,
    bool holdTarget = false,
    int reject = 0,
    int? tunnelPort,
  }) async => LocalSocks(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    holdGreeting: holdGreeting,
    holdTarget: holdTarget,
    reject: reject,
    tunnelPort: tunnelPort,
  );
  void accept(Socket socket) {
    connections.add(socket);
    socket.done.ignore();
    var buffer = <int>[];
    var state = 0;
    Socket? remote;
    Future<void> handling = Future.value();
    void dispose() {
      connections.remove(socket);
      socket.destroy();
      remote?.destroy();
    }

    Future<void> process() async {
      if (holdGreeting) return;
      if (state == 0 && buffer.length >= 3) {
        check(buffer[0] == 5 && buffer[1] == 1 && buffer[2] == 0, 'SOCKS5 no-auth greeting');
        buffer = buffer.sublist(3);
        socket.add([5, 0]);
        state = 1;
      }
      if (state == 1 && buffer.length >= 5 && buffer.length >= 7 + buffer[4]) {
        check(
          buffer[0] == 5 && buffer[1] == 1 && buffer[3] == 3,
          'Target is sent to proxy by name',
        );
        final length = buffer[4];
        targets.add(utf8.decode(buffer.sublist(5, 5 + length)));
        buffer = buffer.sublist(7 + length);
        socket.add([5, reject, 0, 1, 127, 0, 0, 1, 0, 0]);
        state = 2;
        if (reject != 0) return;
        if (tunnelPort != null) {
          remote = await Socket.connect(InternetAddress.loopbackIPv4, tunnelPort!);
          remotes.add(remote!);
          remote!.done.ignore();
          remote!.listen(socket.add, onDone: dispose, onError: (Object _) => dispose());
        }
      }
      if (state == 2 && reject == 0 && !holdTarget && buffer.isNotEmpty) {
        if (remote != null) {
          remote!.add(buffer);
          buffer = [];
          return;
        }
        final text = utf8.decode(buffer);
        final head = text.indexOf('\r\n\r\n');
        if (head < 0) return;
        final length = int.parse(
          RegExp(
                r'content-length:\s*(\d+)',
                caseSensitive: false,
              ).firstMatch(text.substring(0, head))?.group(1) ??
              '0',
        );
        if (buffer.length < head + 4 + length) return;
        requests.add(text);
        buffer = buffer.sublist(head + 4 + length);
        final body = jsonEncode({
          'result': {
            'status': 'OK',
            'height': 100,
            'nettype': 'mainnet',
            'offline': false,
            'synchronized': true,
            'target_height': 100,
          },
        });
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${utf8.encode(body).length}\r\n\r\n$body',
        );
      }
    }

    socket.listen(
      (data) {
        buffer.addAll(data);
        handling = handling.then((_) => process()).catchError((Object _) {
          dispose();
        });
      },
      onDone: dispose,
      onError: (Object _) => dispose(),
    );
  }

  Future<void> waitClosed() async {
    final end = DateTime.now().add(const Duration(seconds: 2));
    while (connections.isNotEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    check(connections.isEmpty, 'Diagnostic closes every proxy socket');
  }

  Future<void> dispose() async {
    for (final socket in connections.toList()) {
      socket.destroy();
    }
    for (final socket in remotes) {
      socket.destroy();
    }
    await server.close();
  }
}

Future<void> main(List<String> arguments) async {
  final proxy = await LocalSocks.start();
  try {
    final health = await probeMoneroNode(
      endpoint: Uri.parse('http://synthetic-no-dns.onion:18081/json_rpc'),
      createClient: () => moneroDiagnosticClient(socksProxy: proxy.endpoint),
      viaProxy: true,
      samples: 1,
    );
    check(
      health.ready && health.viaProxy,
      'RPC is validated through SOCKS, not merely its local port',
    );
    check(
      proxy.targets.single == 'synthetic-no-dns.onion' && proxy.requests.length == 1,
      'Onion target is forwarded without local node DNS lookup',
    );
    await proxy.waitClosed();
    final isolated = await requestMoneroNodeHealth(
      endpoint: Uri.parse('http://synthetic.onion:18081/json_rpc'),
      socksProxy: proxy.endpoint,
      samples: 1,
    );
    check(isolated.ready, 'Production request returns a real successful SOCKS RPC observation');
    await proxy.waitClosed();
  } finally {
    await proxy.dispose();
  }

  for (final reply in [2, 5]) {
    final proxy = await LocalSocks.start(reject: reply);
    try {
      final result = await probeMoneroNode(
        endpoint: Uri.parse('http://synthetic.invalid:18081/json_rpc'),
        createClient: () => moneroDiagnosticClient(socksProxy: proxy.endpoint),
        viaProxy: true,
        samples: 1,
      );
      check(
        result.state ==
            (reply == 2 ? MoneroNodeState.forbidden : MoneroNodeState.connectionRefused),
        'SOCKS refusal $reply is classified without a clearnet fallback',
      );
      check(proxy.requests.isEmpty, 'Refused SOCKS target receives no HTTP');
      await proxy.waitClosed();
    } finally {
      await proxy.dispose();
    }
  }
  final stalled = await LocalSocks.start(holdGreeting: true);
  try {
    final result = await probeMoneroNode(
      endpoint: Uri.parse('http://synthetic.invalid:18081/json_rpc'),
      createClient: () => moneroDiagnosticClient(socksProxy: stalled.endpoint),
      viaProxy: true,
      samples: 1,
      timeout: const Duration(milliseconds: 100),
    );
    check(result.state == MoneroNodeState.timeout, 'Stalled SOCKS handshake has bounded lifetime');
    await stalled.waitClosed();
  } finally {
    await stalled.dispose();
  }

  final stalledTls = await LocalSocks.start(holdTarget: true);
  try {
    final result = await requestMoneroNodeHealth(
      endpoint: Uri.parse('https://synthetic.invalid/json_rpc'),
      socksProxy: stalledTls.endpoint,
      samples: 1,
      timeout: const Duration(milliseconds: 200),
    );
    check(result.state == MoneroNodeState.timeout, 'TLS inside SOCKS obeys the probe deadline');
    await stalledTls.waitClosed();
  } finally {
    await stalledTls.dispose();
  }

  if (arguments.length == 2) {
    final context = SecurityContext()
      ..useCertificateChain(arguments[0])
      ..usePrivateKey(arguments[1]);
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(
        jsonEncode({
          'result': {
            'status': 'OK',
            'height': 100,
            'nettype': 'mainnet',
            'offline': false,
            'synchronized': true,
            'target_height': 100,
          },
        }),
      );
      try {
        await request.response.close();
      } catch (_) {}
    }, onError: (Object _) {});
    final proxy = await LocalSocks.start(tunnelPort: server.port);
    try {
      final health = await probeMoneroNode(
        endpoint: Uri.parse('https://localhost:${server.port}/json_rpc'),
        createClient: () => moneroDiagnosticClient(
          socksProxy: proxy.endpoint,
          securityContext: SecurityContext()..setTrustedCertificates(arguments[0]),
        ),
        viaProxy: true,
        samples: 1,
      );
      check(health.ready, 'TLS through SOCKS validates the original hostname');
      await proxy.waitClosed();
      final bad = await probeMoneroNode(
        endpoint: Uri.parse('https://localhost:${server.port}/json_rpc'),
        createClient: () => moneroDiagnosticClient(socksProxy: proxy.endpoint),
        viaProxy: true,
        samples: 1,
      );
      check(bad.state == MoneroNodeState.tlsError, 'Untrusted TLS through SOCKS is rejected');
      await proxy.waitClosed();
    } finally {
      await proxy.dispose();
      await server.close(force: true);
    }
  }
  String md5Text(String value) => md5.convert(utf8.encode(value)).toString();
  final header = moneroDigestAuthorization(
    'Digest realm="ci", nonce="nonce", qop="auth,auth-int", algorithm=MD5',
    'POST',
    '/json_rpc',
    'user',
    'synthetic-password',
  );
  final cnonce = RegExp(r'cnonce="([a-f0-9]+)"').firstMatch(header)!.group(1)!;
  final expected = md5Text(
    '${md5Text('user:ci:synthetic-password')}:nonce:00000001:$cnonce:auth:${md5Text('POST:/json_rpc')}',
  );
  check(
    header.contains('response="$expected"') && !header.contains('synthetic-password'),
    'Digest binds credentials, nonce, method and target without sending the password',
  );
  var rejected = false;
  try {
    moneroDigestAuthorization(
      'Digest realm="ci", nonce="x", algorithm=SHA-256',
      'POST',
      '/json_rpc',
      'user',
      'synthetic',
    );
  } on MoneroProbeUnavailable {
    rejected = true;
  }
  check(
    rejected,
    'Unsupported Digest algorithms fail explicitly instead of sending wrong credentials',
  );

  print(
    jsonEncode({
      'status': 'passed',
      'checks': checks,
      'externalRequests': 0,
      'paymentsSubmitted': 0,
    }),
  );
}
