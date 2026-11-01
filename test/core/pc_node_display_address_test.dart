import 'package:cake_wallet/utils/node_display_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RPC credentials and query tokens never enter a visible endpoint', () {
    final uri = Uri.parse('https://username:password@node.example:443/v2/private-token?key=secret#fragment');
    expect(displayNodeAddress(uri), 'node.example:443');
  });
  test('IPv6 is bracketed with an explicit port', () {
    expect(displayNodeAddress(Uri.parse('http://[::1]:18081/json_rpc')), '[::1]:18081');
  });
  test('HTTPS default port remains clear', () {
    expect(displayNodeAddress(Uri.parse('https://node.example')), 'node.example:443');
  });
  test('missing endpoints do not invent a connected server', () {
    expect(displayNodeAddress(null), isNull);
    expect(displayNodeAddress(Uri.parse('/local/path')), isNull);
  });
}
