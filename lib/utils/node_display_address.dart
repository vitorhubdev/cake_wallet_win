/// Only display host and port. Never include user-info, RPC key paths or queries.
String? displayNodeAddress(Uri? uri) {
  if (uri == null || uri.host.isEmpty) return null;
  final host = uri.host;
  final safeHost = host.contains(':') ? '[$host]' : host;
  return uri.port > 0 ? '$safeHost:${uri.port}' : safeHost;
}
