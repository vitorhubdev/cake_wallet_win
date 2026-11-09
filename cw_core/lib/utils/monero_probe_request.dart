import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../monero_node_health.dart';
import 'monero_probe_transport.dart';

/// All sockets belong to this bounded request, including proxy/TLS setup.
Future<MoneroNodeHealth> requestMoneroNodeHealth({
  required Uri endpoint,
  String? socksProxy,
  String login = '',
  String password = '',
  String expectedNetwork = 'mainnet',
  int samples = 3,
  Duration timeout = const Duration(seconds: 15),
  MoneroProbeCancellation? cancellation,
}) => probeMoneroNode(
  endpoint: endpoint,
  createClient: () => moneroDiagnosticClient(socksProxy: socksProxy),
  expectedNetwork: expectedNetwork,
  samples: samples,
  timeout: timeout,
  viaProxy: socksProxy?.isNotEmpty == true,
  cancellation: cancellation,
  digestHeader: login.isEmpty
      ? null
      : (challenge, method, target) =>
            moneroDigestAuthorization(challenge, method, target, login, password),
);

/// Monerod's MD5 Digest challenge. No raw server body or secret is logged.
String moneroDigestAuthorization(
  String challenge,
  String method,
  String target,
  String username,
  String password,
) {
  if (challenge.length > 4096 ||
      !challenge.toLowerCase().startsWith('digest ') ||
      RegExp(r'[\r\n]').hasMatch(challenge + username + target)) {
    throw const MoneroProbeUnavailable(MoneroNodeState.authenticationRequired);
  }
  final fields = <String, String>{};
  for (final match in RegExp(
    r'(\w+)\s*=\s*(?:"((?:\\.|[^"])*)"|([^,\s]+))',
  ).allMatches(challenge.substring(7))) {
    fields[match[1]!.toLowerCase()] = (match[2] ?? match[3]!).replaceAllMapped(
      RegExp(r'\\(.)'),
      (m) => m[1]!,
    );
  }
  final realm = fields['realm'];
  final nonce = fields['nonce'];
  final algorithm = fields['algorithm']?.toUpperCase() ?? 'MD5';
  final qop = fields['qop'];
  if (realm == null ||
      nonce == null ||
      nonce.isEmpty ||
      algorithm != 'MD5' ||
      (qop != null && !qop.split(',').map((v) => v.trim()).contains('auth'))) {
    throw const MoneroProbeUnavailable(MoneroNodeState.authenticationRequired);
  }
  String hash(String text) => md5.convert(utf8.encode(text)).toString();
  String quote(String text) => text.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  final random = Random.secure();
  final cnonce = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final ha1 = hash('$username:$realm:$password');
  final ha2 = hash('$method:$target');
  final response = qop == null
      ? hash('$ha1:$nonce:$ha2')
      : hash('$ha1:$nonce:00000001:$cnonce:auth:$ha2');
  return 'Digest username="${quote(username)}", realm="${quote(realm)}", '
      'nonce="${quote(nonce)}", uri="${quote(target)}", response="$response"'
      '${qop == null ? '' : ', qop=auth, nc=00000001, cnonce="$cnonce"'}'
      '${fields['opaque'] == null ? '' : ', opaque="${quote(fields['opaque']!)}"'}';
}
