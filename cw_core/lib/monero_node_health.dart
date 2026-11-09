import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

enum MoneroNodeState {
  ready,
  syncing,
  offline,
  unknownReadiness,
  wrongNetwork,
  authenticationRequired,
  forbidden,
  rateLimited,
  serverError,
  rpcError,
  invalidResponse,
  redirect,
  tlsError,
  dnsFailure,
  connectionRefused,
  networkFailure,
  timeout,
  proxyUnavailable,
  invalidConfig,
}

/// Read-only observations, not proof of node honesty or blockchain validation.
/// Never retain response bodies, credentials, proxy addresses or a user's IP.
class MoneroNodeHealth {
  const MoneroNodeHealth({
    required this.state,
    required this.checkedAt,
    this.latencyMs,
    this.jitterMs,
    this.samples = 0,
    this.httpStatus,
    this.height,
    this.targetHeight,
    this.retryAfter,
    this.viaProxy = false,
    this.bootstrap = false,
    this.tls = false,
  });
  final MoneroNodeState state;
  final DateTime checkedAt;
  final int? latencyMs;
  final int? jitterMs;
  final int samples;
  final int? httpStatus;
  final int? height;
  final int? targetHeight;
  final Duration? retryAfter;
  final bool viaProxy;
  final bool bootstrap;
  final bool tls;

  bool get ready => state == MoneroNodeState.ready;
  bool get rpcAvailable =>
      ready || state == MoneroNodeState.syncing || state == MoneroNodeState.unknownReadiness;
  bool get fresh =>
      DateTime.now().difference(checkedAt).inSeconds >= 0 &&
      DateTime.now().difference(checkedAt) <= const Duration(minutes: 2);

  /// Ready nodes are ranked ahead of a low-latency but unusable endpoint.
  static int compare(MoneroNodeHealth? a, MoneroNodeHealth? b) {
    int rank(MoneroNodeHealth? value) => value == null || !value.fresh
        ? 3
        : value.ready
        ? (value.bootstrap ? 1 : 0)
        : value.rpcAvailable
        ? 2
        : 4;
    final order = rank(a).compareTo(rank(b));
    return order != 0 ? order : (a?.latencyMs ?? 1 << 30).compareTo(b?.latencyMs ?? 1 << 30);
  }
}

class MoneroProbeUnavailable implements Exception {
  const MoneroProbeUnavailable(this.state);
  final MoneroNodeState state;
}

/// An explicitly cancelled probe closes its owned socket without touching the
/// native wallet. Closing a settings page must not leave diagnostics running.
class MoneroProbeCancellation {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};
  bool get cancelled => _cancelled;
  void add(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void remove(void Function() listener) => _listeners.remove(listener);
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }
}

typedef MoneroDigestHeader = String Function(String challenge, String method, String path);

/// One bounded get_info exchange (plus authentication if challenged). No POST
/// replay after response failure, no redirects, no TLS bypass, no wallet data.
Future<MoneroNodeHealth> probeMoneroNode({
  required Uri endpoint,
  required FutureOr<HttpClient> Function() createClient,
  String expectedNetwork = 'mainnet',
  MoneroDigestHeader? digestHeader,
  bool viaProxy = false,
  int samples = 3,
  Duration timeout = const Duration(seconds: 15),
  MoneroProbeCancellation? cancellation,
}) async {
  final checkedAt = DateTime.now();
  final latencies = <int>[];
  HttpClient? client;
  HttpClientRequest? activeRequest;
  var finished = false;
  var stopped = false;
  int? status;
  void close() {
    stopped = true;
    activeRequest?.abort();
    client?.close(force: true);
  }

  MoneroNodeHealth result(
    MoneroNodeState state, {
    int? height,
    int? target,
    Duration? retryAfter,
    bool bootstrap = false,
  }) {
    final ordered = latencies.toList()..sort();
    final median = ordered.isEmpty ? null : ordered[ordered.length ~/ 2];
    return MoneroNodeHealth(
      state: state,
      checkedAt: checkedAt,
      latencyMs: median,
      samples: ordered.length,
      jitterMs: ordered.length < 2 ? null : ordered.last - ordered.first,
      httpStatus: status,
      height: height,
      targetHeight: target,
      retryAfter: retryAfter,
      viaProxy: viaProxy,
      bootstrap: bootstrap,
      tls: endpoint.scheme == 'https',
    );
  }

  if (samples < 1 ||
      samples > 3 ||
      timeout <= Duration.zero ||
      endpoint.host.isEmpty ||
      !{'https', 'http'}.contains(endpoint.scheme) ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasFragment ||
      !{'mainnet', 'testnet', 'stagenet'}.contains(expectedNetwork)) {
    return result(MoneroNodeState.invalidConfig);
  }
  if (endpoint.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '').endsWith('.onion') &&
      !viaProxy) {
    return result(MoneroNodeState.proxyUnavailable);
  }
  cancellation?.add(close);
  Future<MoneroNodeHealth> run() async {
    if (stopped) throw const MoneroProbeUnavailable(MoneroNodeState.timeout);
    final ownedClient = await createClient();
    if (finished || stopped) {
      ownedClient.close(force: true);
      throw const MoneroProbeUnavailable(MoneroNodeState.timeout);
    }
    client = ownedClient;
    client!.connectionTimeout = timeout;
    client!.autoUncompress = false;
    // Externally supplied client factories may route SOCKS, but cannot turn a
    // diagnostic into an insecure certificate test by accepting every cert.
    client!.badCertificateCallback = null;
    Future<HttpClientResponse> send({String? authorization}) async {
      if (stopped || finished) throw const MoneroProbeUnavailable(MoneroNodeState.timeout);
      final request = await client!.postUrl(endpoint);
      if (stopped || finished) {
        request.abort();
        throw const MoneroProbeUnavailable(MoneroNodeState.timeout);
      }
      activeRequest = request;
      request.followRedirects = false;
      request.maxRedirects = 0;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (authorization != null)
        request.headers.set(HttpHeaders.authorizationHeader, authorization);
      // monerod's HTTP parser expects a fixed-length JSON request. Dart's
      // default chunked encoding can otherwise produce HTTP 200 + RPC errors.
      final payload = utf8.encode(
        '{"jsonrpc":"2.0","id":"pc-health","method":"get_info","params":{}}',
      );
      request.contentLength = payload.length;
      request.add(payload);

      return request.close();
    }

    Future<List<int>> boundedBody(HttpClientResponse response) async {
      const maximum = 64 * 1024;
      if (response.contentLength > maximum) throw const FormatException('RPC response too large');
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maximum)
          throw const FormatException('RPC response too large');
        bytes.addAll(chunk);
      }
      return bytes;
    }

    MoneroNodeHealth? last;
    for (var sample = 0; sample < samples; sample++) {
      final watch = Stopwatch()..start();
      var response = await send();
      status = response.statusCode;
      if (status == 401 && digestHeader != null) {
        final challenge = response.headers.value(HttpHeaders.wwwAuthenticateHeader);
        if (challenge == null || !challenge.toLowerCase().startsWith('digest ')) {
          return result(MoneroNodeState.authenticationRequired);
        }
        await boundedBody(response);
        final path = endpoint.path + (endpoint.hasQuery ? '?${endpoint.query}' : '');
        final authorization = digestHeader(challenge, 'POST', path);
        response = await send(authorization: authorization);
        status = response.statusCode;
      }
      final failure = switch (status!) {
        401 || 407 => MoneroNodeState.authenticationRequired,
        403 || 451 => MoneroNodeState.forbidden,
        429 => MoneroNodeState.rateLimited,
        >= 300 && < 400 => MoneroNodeState.redirect,
        >= 500 => MoneroNodeState.serverError,
        != 200 => MoneroNodeState.rpcError,
        _ => null,
      };
      if (failure != null) {
        return result(
          failure,
          retryAfter: parseMoneroRetryAfter(
            response.headers.value(HttpHeaders.retryAfterHeader),
            checkedAt,
          ),
        );
      }
      final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        return result(MoneroNodeState.invalidResponse);
      }
      final bytes = await boundedBody(response);
      final decoded = jsonDecode(utf8.decode(bytes));
      watch.stop();
      if (decoded is! Map<String, dynamic> ||
          decoded['error'] != null ||
          decoded['result'] is! Map<String, dynamic>) {
        return result(MoneroNodeState.invalidResponse);
      }
      final info = decoded['result'] as Map<String, dynamic>;
      final state = classifyMoneroNode(info, expectedNetwork: expectedNetwork);
      if (state == MoneroNodeState.invalidResponse) return result(state);
      // RTT includes DNS, TCP, TLS/auth and the complete small RPC response;
      // this is not ICMP ping or blockchain download throughput.
      latencies.add(math.max(1, watch.elapsedMilliseconds));
      last = result(
        state,
        height: _height(info['height']),
        target: _height(info['target_height']),
        bootstrap: info['untrusted'] == true,
      );
      if (!last.ready) return last;
      if (sample + 1 < samples) await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return last!;
  }

  try {
    return await run().timeout(timeout);
  } on MoneroProbeUnavailable catch (error) {
    return result(error.state);
  } on HandshakeException {
    return result(MoneroNodeState.tlsError);
  } on TlsException {
    return result(MoneroNodeState.tlsError);
  } on TimeoutException {
    return result(MoneroNodeState.timeout);
  } on SocketException catch (error) {
    final code = error.osError?.errorCode;
    if ({111, 61, 1225, 10061}.contains(code)) return result(MoneroNodeState.connectionRefused);
    // DNS descriptions are used only for classification, never retained/displayed.
    final message = error.message.toLowerCase();
    if (message.contains('host lookup') ||
        message.contains('name or service') ||
        message.contains('getaddrinfo'))
      return result(MoneroNodeState.dnsFailure);
    return result(MoneroNodeState.networkFailure);
  } on FormatException {
    return result(MoneroNodeState.invalidResponse);
  } on HttpException {
    return result(MoneroNodeState.networkFailure);
  } catch (_) {
    return result(MoneroNodeState.invalidResponse);
  } finally {
    finished = true;
    cancellation?.remove(close);
    close();
  }
}

int? _height(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991 ? value : null;

MoneroNodeState classifyMoneroNode(
  Map<String, dynamic> info, {
  String expectedNetwork = 'mainnet',
}) {
  if (info['status'] == 'BUSY') return MoneroNodeState.syncing;
  if (info['status'] != 'OK') return MoneroNodeState.rpcError;
  final height = _height(info['height']);
  if (height == null) return MoneroNodeState.invalidResponse;
  final declared = info['nettype'];
  final network = declared is String
      ? declared
      : info['testnet'] == true
      ? 'testnet'
      : info['stagenet'] == true
      ? 'stagenet'
      : info['mainnet'] == true
      ? 'mainnet'
      : null;
  if (network == null) return MoneroNodeState.unknownReadiness;
  if (network != expectedNetwork ||
      (expectedNetwork != 'testnet' && info['testnet'] == true) ||
      (expectedNetwork != 'stagenet' && info['stagenet'] == true)) {
    return MoneroNodeState.wrongNetwork;
  }
  if (info['offline'] == true) return MoneroNodeState.offline;
  if (height == 0 || info['synchronized'] == false || info['busy_syncing'] == true) {
    return MoneroNodeState.syncing;
  }
  final target = _height(info['target_height']);
  if (target != null && target > height) return MoneroNodeState.syncing;
  if (info['offline'] != false || info['synchronized'] != true) {
    return MoneroNodeState.unknownReadiness;
  }
  return MoneroNodeState.ready;
}

Duration? parseMoneroRetryAfter(String? value, DateTime now) {
  if (value == null || value.length > 128) return null;
  var seconds = int.tryParse(value.trim());
  if (seconds == null) {
    try {
      seconds = HttpDate.parse(value).difference(now).inSeconds;
    } catch (_) {
      return null;
    }
  }
  return seconds < 0 ? null : Duration(seconds: math.min(seconds, 24 * 60 * 60));
}
