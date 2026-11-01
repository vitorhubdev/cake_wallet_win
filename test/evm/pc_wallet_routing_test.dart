import 'dart:async';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/payment_uris.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_evm/clients/evm_chain_client.dart';
import 'package:cw_evm/evm_chain_exceptions.dart';
import 'package:cw_evm/evm_chain_transaction_credentials.dart';
import 'package:cw_evm/evm_chain_transaction_history.dart';
import 'package:cw_evm/evm_chain_wallet.dart';
import 'package:cw_evm/evm_chain_wallet_addresses.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Info extends Mock implements WalletInfo {}
class _Files extends EncryptionFileUtils {
  @override
  Future<void> write({required String path, required String password, required String data}) async {}
  @override
  Future<String> read({required String path, required String password}) async => '';
}
class _RejectedRPC extends EVMChainClient {
  _RejectedRPC() : super(chainId: 1);
  final replies = <Completer<bool>>[];
  int stops = 0;
  @override
  bool connect(Node node) => true;
  @override
  Future<bool> verifyChainId({Duration timeout = const Duration(seconds: 10)}) {
    final reply = Completer<bool>();
    replies.add(reply);
    return reply.future;
  }
  @override
  void stop() { stops++; super.stop(); }
}

// Only database/network effects are replaced. selectChain and createTransaction
// themselves execute the production methods, with no keys, funds or RPC traffic.
class _SwitchingWallet extends EVMChainWallet {
  _SwitchingWallet(WalletInfo info) : super(
      walletInfo: info, derivationInfo: DerivationInfo(),
      client: EVMChainClient(chainId: 1), nativeCurrency: CryptoCurrency.eth,
      password: 'test-only', encryptionFileUtils: _Files());
  @override
  Future<void> connectToNode({required Node node}) async {}
  @override
  Future<void> initErc20Tokens() async {}
  @override
  Future<void> save() async {}
  @override
  Future<void> startSync() async {}
  @override
  EVMChainTransactionHistory setUpTransactionHistory(
      WalletInfo info, String password, EncryptionFileUtils files) =>
      EVMChainTransactionHistory(walletInfo: info, password: password,
          encryptionFileUtils: files, getCurrentChainId: () => selectedChainId,
          directoryResolver: () async => '/synthetic-fixture');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Info info;
  final node = Node(uri: 'fixture.invalid:443', type: WalletType.ethereum, useSSL: true);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    info = _Info();
    when(() => info.type).thenReturn(WalletType.ethereum);
    when(() => info.name).thenReturn('unfunded-routing-fixture');
    when(() => info.id).thenReturn('ethereum_unfunded-routing-fixture');
    when(() => info.address).thenReturn('0x0000000000000000000000000000000000000001');
    when(() => info.getUsedAddresses()).thenAnswer((_) async => <String>{});
    when(() => info.getHiddenAddresses()).thenAnswer((_) async => <String>{});
    when(() => info.getManualAddresses()).thenAnswer((_) async => <String>{});
  });

  test('actual network selection updates the receive QR chain without changing address', () async {
    final wallet = _SwitchingWallet(info);
    addTearDown(wallet.close);
    wallet.walletAddresses.address = info.address;
    for (final chain in [137, 8453, 42161, 56, 4663, 1]) {
      await wallet.selectChain(chain, node: node);
      final uri = wallet.walletAddresses.getPaymentUri('1.25') as ERC681URI;
      expect(uri.chainId, chain);
      expect(uri.address, info.address);
      expect(uri.toString(), contains('@$chain'));
    }
  });
  test('queued network selections leave receive URI on the last selected chain', () async {
    final wallet = _SwitchingWallet(info);
    addTearDown(wallet.close);
    await Future.wait([wallet.selectChain(137, node: node), wallet.selectChain(8453, node: node)]);
    expect(wallet.selectedChainId, 8453);
    expect((wallet.walletAddresses.getPaymentUri('') as ERC681URI).chainId, 8453);
  });
  test('invalid receive URI chain is rejected', () {
    final addresses = EVMChainWalletAddresses(info, 1);
    expect(() => addresses.setChainId(0), throwsArgumentError);
    expect(() => addresses.setChainId(-1), throwsArgumentError);
    expect((addresses.getPaymentUri('') as ERC681URI).chainId, 1);
  });
  for (final count in [0, 2, 3]) {
    test('$count recipients are rejected before balance lookup, signing or RPC', () async {
      final wallet = _SwitchingWallet(info);
      addTearDown(wallet.close);
      final outputs = List.generate(count, (i) => OutputInfo(
          address: '0x${(i + 1).toRadixString(16).padLeft(40, '0')}',
          sendAll: false, isParsedAddress: false,
          cryptoAmount: Money.fromInt(1, CryptoCurrency.eth)));
      await expectLater(wallet.createTransaction(EVMChainTransactionCredentials(
          outputs, priority: null, currency: CryptoCurrency.eth)),
          throwsA(isA<EVMChainTransactionCreationException>()));
    });
  }
  test('wrong-chain connection is stopped instead of remaining usable for sending', () async {
    final client = _RejectedRPC();
    final wallet = EVMChainWallet(walletInfo: info, derivationInfo: DerivationInfo(),
        client: client, nativeCurrency: CryptoCurrency.eth,
        password: 'test-only', encryptionFileUtils: _Files());
    final connection = wallet.connectToNode(node: node);
    client.replies.single.complete(false);
    await connection;
    expect(wallet.syncStatus, isA<FailedSyncStatus>());
    expect(client.stops, 1);
    await wallet.close();
  });
  test('stale rejected connection does not stop its replacement', () async {
    final client = _RejectedRPC();
    final wallet = EVMChainWallet(walletInfo: info, derivationInfo: DerivationInfo(),
        client: client, nativeCurrency: CryptoCurrency.eth,
        password: 'test-only', encryptionFileUtils: _Files());
    final older = wallet.connectToNode(node: node);
    final newer = wallet.connectToNode(node: node);
    client.replies[1].complete(false);
    await newer;
    expect(client.stops, 1);
    client.replies[0].complete(false);
    await older;
    expect(client.stops, 1);
    await wallet.close();
  });
}
