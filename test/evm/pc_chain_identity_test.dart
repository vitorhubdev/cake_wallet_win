import 'dart:async';
import 'dart:convert';

import 'package:cw_evm/clients/evm_chain_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:web3dart/web3dart.dart';

class _OwnedTransport extends http.BaseClient {
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => throw UnimplementedError();
  @override
  void close() { closes++; }
}

void main() {
  Web3Client rpc(Future<http.Response> Function(http.Request) respond) =>
      Web3Client('https://not-used.invalid', MockClient(respond));
  http.Response result(http.Request request, Object value) => http.Response(
      jsonEncode({'jsonrpc': '2.0', 'id': jsonDecode(request.body)['id'], 'result': value}), 200);

  for (final chain in [1, 137, 8453, 42161, 56, 4663]) {
    test('RPC chain identity $chain is checked using eth_chainId', () async {
      final transport = rpc((request) async {
        expect(jsonDecode(request.body)['method'], 'eth_chainId');
        return result(request, '0x${chain.toRadixString(16)}');
      });
      addTearDown(transport.dispose);
      final client = EVMChainClient(chainId: chain, rpcClient: transport);
      expect(await client.verifyChainId(), isTrue);
    });
  }
  test('a responsive node on another network is rejected', () async {
    final transport = rpc((request) async => result(request, '0x89'));
    addTearDown(transport.dispose);
    expect(await EVMChainClient(chainId: 1, rpcClient: transport).verifyChainId(), isFalse);
  });
  test('a malformed chain identifier is rejected', () async {
    final transport = rpc((request) async => result(request, 'not-a-chain'));
    addTearDown(transport.dispose);
    expect(await EVMChainClient(chainId: 1, rpcClient: transport).verifyChainId(), isFalse);
  });
  test('an unconnected client cannot be healthy', () async {
    expect(await EVMChainClient(chainId: 1).verifyChainId(), isFalse);
  });
  test('RPC errors are not accepted as a matching chain', () async {
    final transport = rpc((request) async => http.Response(jsonEncode({
      'jsonrpc': '2.0', 'id': jsonDecode(request.body)['id'],
      'error': {'code': -32601, 'message': 'unsupported'},
    }), 200));
    addTearDown(transport.dispose);
    expect(await EVMChainClient(chainId: 1, rpcClient: transport).verifyChainId(), isFalse);
  });
  test('stopping the connection invalidates a delayed matching response', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    late http.Request request;
    final transport = rpc((req) {
      request = req;
      started.complete();
      return response.future;
    });
    final client = EVMChainClient(chainId: 1, rpcClient: transport);
    final check = client.verifyChainId();
    await started.future;
    client.stop();
    response.complete(result(request, '0x1'));
    expect(await check, isFalse);
  });
  test('stopping disposes its owned HTTP pool exactly once', () {
    final transport = _OwnedTransport();
    final client = EVMChainClient(chainId: 1, httpClient: transport);
    client.stop();
    client.stop();
    expect(transport.closes, 1);
  });
  test('the chain check has a finite caller deadline', () async {
    final response = Completer<http.Response>();
    late http.Request request;
    final transport = rpc((req) { request = req; return response.future; });
    addTearDown(transport.dispose);
    final client = EVMChainClient(chainId: 1, rpcClient: transport);
    expect(await client.verifyChainId(timeout: const Duration(milliseconds: 20)), isFalse);
    // Finish the simulated transport too. A Future timeout is not socket cancellation.
    response.complete(result(request, '0x1'));
  });
}
