import 'dart:async';
import 'dart:io';

/// Prefer IPv6 while establishing TCP, before any HTTP request is written.
///
/// A failed response is never a reason to replay a POST on another address.
/// Direct HTTPS uses a cancellable SecureSocket with the hostname retained by
/// DNS lookup, preserving SNI and certificate verification. HTTP proxy tunnels
/// remain HttpClient's responsibility; SOCKS/Tor clients do not use this factory.
Future<ConnectionTask<Socket>> connectPreferIPv6(
  Uri uri,
  String? proxyHost,
  int? proxyPort, {
  Future<List<InternetAddress>> Function(String)? lookup,
  SecurityContext? securityContext,
  bool Function(X509Certificate)? onBadCertificate,
  Duration lookupTimeout = const Duration(seconds: 2),
  Duration connectTimeout = const Duration(seconds: 3),
}) async {
  final host = proxyHost ?? uri.host;
  final port = proxyHost == null ? uri.port : proxyPort;
  if (port == null || port < 1 || port > 65535) {
    throw ArgumentError.value(port, 'port', 'Expected a valid destination port');
  }

  var cancelled = false;
  ConnectionTask<Socket>? pending;
  Socket? connected;

  void ensureActive() {
    if (cancelled) throw const SocketException('Connection attempt cancelled');
  }

  Future<Socket> connect() async {
    final literal = InternetAddress.tryParse(host);
    Future<List<InternetAddress>> family(InternetAddressType type) async {
      try {
        return await InternetAddress.lookup(host, type: type).timeout(lookupTimeout);
      } on SocketException {
        return <InternetAddress>[];
      } on TimeoutException {
        return <InternetAddress>[];
      }
    }

    // Generic DNS lookup can suppress IPv6 (AI_ADDRCONFIG), even when the
    // loopback or an explicit IPv6 route is usable. Query both families.
    final addresses = literal != null
        ? <InternetAddress>[literal]
        : lookup != null
        ? await lookup(host).timeout(lookupTimeout)
        : (await Future.wait([family(InternetAddressType.IPv6), family(InternetAddressType.IPv4)]))
              .expand((addresses) => addresses)
              .toList();
    ensureActive();
    final ordered = <InternetAddress>[
      ...addresses.where(
        (a) => a.type == InternetAddressType.IPv6 && !a.address.startsWith('::ffff:'),
      ),
      ...addresses.where(
        (a) => a.type != InternetAddressType.IPv6 || a.address.startsWith('::ffff:'),
      ),
    ];
    if (ordered.isEmpty) {
      throw SocketException('No usable address for $host');
    }

    Object? lastError;
    // Bound the aggregate connect work as well as each individual attempt.
    // Retain IPv4 fallback even if a hostname advertises many IPv6 addresses.
    final candidates = <InternetAddress>[
      ...ordered
          .where((a) => a.type == InternetAddressType.IPv6 && !a.address.startsWith('::ffff:'))
          .take(2),
      ...ordered
          .where((a) => a.type == InternetAddressType.IPv4 || a.address.startsWith('::ffff:'))
          .take(2),
    ];
    for (final address in candidates) {
      ensureActive();
      try {
        final ConnectionTask<Socket> task = uri.isScheme('https') && proxyHost == null
            ? await SecureSocket.startConnect(
                address,
                port,
                context: securityContext,
                onBadCertificate: onBadCertificate,
              )
            : await Socket.startConnect(address, port);
        pending = task;
        if (cancelled) {
          task.cancel();
          // Consume the cancellation error before leaving the attempt.
          await task.socket.then<void>(
            (socket) => socket.destroy(),
            onError: (Object _, StackTrace __) {},
          );
          ensureActive();
        }
        final socket = await task.socket.timeout(
          connectTimeout,
          onTimeout: () {
            task.cancel();
            // Timeout does not cancel the underlying future. Dispose a late
            // successful socket instead of leaking it behind the next attempt.
            unawaited(
              task.socket.then<void>(
                (socket) => socket.destroy(),
                onError: (Object _, StackTrace __) {},
              ),
            );
            throw TimeoutException('TCP connection timed out', connectTimeout);
          },
        );
        if (cancelled) {
          socket.destroy();
          ensureActive();
        }
        connected = socket;
        return socket;
      } on SocketException catch (error) {
        lastError = error;
      } on TimeoutException catch (error) {
        lastError = error;
      } finally {
        pending = null;
      }
    }
    ensureActive();
    if (lastError != null) throw lastError;
    throw SocketException('No usable address for $host');
  }

  return ConnectionTask.fromSocket(connect(), () {
    cancelled = true;
    pending?.cancel();
    connected?.destroy();
  });
}
