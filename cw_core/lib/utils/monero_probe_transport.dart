import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:socks5_proxy/src/client/socks_client.dart';
import 'package:socks5_proxy/src/enums/socks_connection_type.dart';

import '../monero_node_health.dart';

/// The repository pins socks5_proxy at 27ad7c2. Its public connection helper
/// cannot cancel an unfinished SOCKS handshake. Reuse its Socket/stream adapter
/// while owning the TCP connection before beginning the bounded handshake.
Future<HttpClient> moneroDiagnosticClient({
  String? socksProxy,
  SecurityContext? securityContext,
  Duration handshakeTimeout = const Duration(seconds: 8),
}) async {
  if (socksProxy == null || socksProxy.isEmpty) return HttpClient(context: securityContext);
  final proxy = Uri.tryParse('socks5://$socksProxy');
  if (proxy == null ||
      proxy.host.isEmpty ||
      !proxy.hasPort ||
      proxy.port < 1 ||
      proxy.port > 65535 ||
      proxy.userInfo.isNotEmpty ||
      proxy.path.isNotEmpty ||
      proxy.hasQuery ||
      proxy.hasFragment) {
    throw const MoneroProbeUnavailable(MoneroNodeState.proxyUnavailable);
  }
  final addresses = await InternetAddress.lookup(proxy.host).timeout(const Duration(seconds: 2));
  if (addresses.isEmpty) throw const MoneroProbeUnavailable(MoneroNodeState.proxyUnavailable);
  final client = HttpClient(context: securityContext);
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    var cancelled = false;
    ConnectionTask<Socket>? tcpTask;
    Socket? raw;
    _DiagnosticSocksSocket? socks;
    Socket? completed;
    ServerSocket? relayListener;
    Socket? relayPeer;
    Socket? tlsInput;
    void cancel() {
      cancelled = true;
      tcpTask?.cancel();
      socks?.destroy();
      raw?.destroy();
      completed?.destroy();
      relayPeer?.destroy();
      tlsInput?.destroy();
      unawaited(relayListener?.close());
    }

    void active() {
      if (cancelled) throw const SocketException('Monero diagnostic transport cancelled');
    }

    Future<Socket> open() async {
      try {
        final task = tcpTask = await Socket.startConnect(addresses.first, proxy.port);
        if (cancelled) task.cancel();
        raw = await task.socket;
        if (cancelled) raw!.destroy();
        active();
        socks = _DiagnosticSocksSocket(raw!);
        await socks!.connectTarget(uri.host, uri.port);
        active();
        Socket connected;
        if (uri.scheme == 'https') {
          // SecureSocket.secure detaches its input socket before its Future
          // completes; destroying that old input no longer cancels a stalled
          // handshake. Keep an owned loopback peer so cancellation can close
          // the actual TLS transport at every stage. The listener accepts one
          // connection only and validates its exact local source port before
          // forwarding any bytes. It never binds outside loopback.
          relayListener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          active();
          final accepted = relayListener!.first;
          accepted.ignore(); // cancellation may close the listener before connect completes
          tlsInput = await Socket.connect(InternetAddress.loopbackIPv4, relayListener!.port);
          relayPeer = await accepted;
          await relayListener!.close();
          relayListener = null;
          if (relayPeer!.remotePort != tlsInput!.port || !relayPeer!.remoteAddress.isLoopback) {
            throw const SocketException('Diagnostic relay peer mismatch');
          }
          active();
          relayPeer!.done.ignore();
          socks!.done.ignore();
          socks!.listen(
            (bytes) {
              try {
                if (!cancelled) relayPeer!.add(bytes);
              } catch (_) {
                cancel();
              }
            },
            onDone: () => relayPeer?.destroy(),
            onError: (Object _) => relayPeer?.destroy(),
          );
          relayPeer!.listen(
            (bytes) {
              try {
                if (!cancelled) socks!.add(bytes);
              } catch (_) {
                cancel();
              }
            },
            onDone: () => socks?.destroy(),
            onError: (Object _) => socks?.destroy(),
          );
          connected = await SecureSocket.secure(
            tlsInput!,
            host: uri.host,
            context: securityContext,
          );
        } else {
          connected = socks!;
        }
        if (cancelled) connected.destroy();
        active();
        completed = connected;
        return connected;
      } catch (_) {
        cancel();
        rethrow;
      }
    }

    final pending = open();
    final bounded = pending.timeout(
      handshakeTimeout,
      onTimeout: () {
        cancel();
        unawaited(
          pending.then<void>((socket) => socket.destroy(), onError: (Object _, StackTrace __) {}),
        );
        throw TimeoutException('SOCKS/TLS handshake deadline exceeded', handshakeTimeout);
      },
    );
    return ConnectionTask.fromSocket(bounded, cancel);
  };
  return client;
}

class _DiagnosticSocksSocket extends SocksSocket {
  _DiagnosticSocksSocket(Socket socket) : super.protected(socket, SocksConnectionType.connect);

  Future<void> connectTarget(String host, int port) async {
    final hostname = utf8.encode(host);
    if (hostname.isEmpty || hostname.length > 255 || port < 1 || port > 65535) {
      throw const MoneroProbeUnavailable(MoneroNodeState.invalidConfig);
    }
    add(Uint8List.fromList([5, 1, 0]));
    await flush();
    final version = await readUint8();
    final authentication = await readUint8();
    if (version != 5 || authentication != 0) {
      throw const MoneroProbeUnavailable(MoneroNodeState.proxyUnavailable);
    }
    // Domain form deliberately defers target resolution to the proxy, including
    // .onion destinations. Never resolve the node through local DNS.
    add(Uint8List.fromList([5, 1, 0, 3, hostname.length, ...hostname, port >> 8, port & 255]));
    await flush();
    final responseVersion = await readUint8();
    final reply = await readUint8();
    final reserved = await readUint8();
    final type = await readUint8();
    if (responseVersion != 5 || reserved != 0) {
      throw const MoneroProbeUnavailable(MoneroNodeState.proxyUnavailable);
    }
    if (reply != 0) {
      throw MoneroProbeUnavailable(
        reply == 2
            ? MoneroNodeState.forbidden
            : reply == 5
            ? MoneroNodeState.connectionRefused
            : MoneroNodeState.networkFailure,
      );
    }
    final length = type == 1
        ? 4
        : type == 4
        ? 16
        : type == 3
        ? await readUint8()
        : -1;
    if (length < 0) throw const MoneroProbeUnavailable(MoneroNodeState.proxyUnavailable);
    for (var i = 0; i < length + 2; i++) {
      await readUint8();
    }
  }
}
