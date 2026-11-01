import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/output_info.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_evm/clients/evm_chain_client.dart';
import 'package:cw_evm/evm_chain_exceptions.dart';
import 'package:cw_evm/evm_chain_transaction_credentials.dart';
import 'package:cw_evm/evm_chain_transaction_history.dart';
import 'package:cw_evm/evm_chain_wallet.dart';
import 'package:cw_evm/evm_erc20_balance.dart';
import 'package:cw_evm/utils/transaction_currency.dart';
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

// Production transaction/chain-selection logic with only IO and fee RPC mocked.
// No private key is initialized: stale preparation must stop before signing.
class _FeeControlledWallet extends EVMChainWallet {
  _FeeControlledWallet(WalletInfo info) : super(
      walletInfo: info, derivationInfo: DerivationInfo(),
      client: EVMChainClient(chainId: 1), nativeCurrency: CryptoCurrency.eth,
      initialBalance: EVMChainERC20Balance(Money.fromInt(1000000, CryptoCurrency.eth)),
      password: 'test-only', encryptionFileUtils: _Files());
  final feeStarted = Completer<void>();
  final feeResult = Completer<GasParamsHandler>();
  Uint8List? estimatedData;
  @override
  Future<GasParamsHandler> calculateActualEstimatedFeeForCreateTransaction({
    required Money amount, required String? contractAddress,
    required String receivingAddressHex, required TransactionPriority? priority,
    Uint8List? data,
  }) {
    estimatedData = data;
    if (!feeStarted.isCompleted) feeStarted.complete();
    return feeResult.future;
  }
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
          directoryResolver: () async => '/synthetic-transaction-fixture');
}

Erc20Token token(String address, {int? chain = 1, int decimals = 6}) => Erc20Token(
    name: 'Same display name', symbol: 'TOKEN', contractAddress: address,
    decimal: decimals, chainId: chain, tag: 'ETH');
const firstContract = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const secondContract = '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Info info;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    info = _Info();
    when(() => info.type).thenReturn(WalletType.ethereum);
    when(() => info.name).thenReturn('unfunded-transaction-fixture');
    when(() => info.id).thenReturn('ethereum_unfunded-transaction-fixture');
    when(() => info.address).thenReturn('0x0000000000000000000000000000000000000001');
    when(() => info.getUsedAddresses()).thenAnswer((_) async => <String>{});
    when(() => info.getHiddenAddresses()).thenAnswer((_) async => <String>{});
    when(() => info.getManualAddresses()).thenAnswer((_) async => <String>{});
  });
  test('same-symbol tokens are selected by contract, not insertion order', () {
    final first = token(firstContract), second = token(secondContract);
    expect(resolveEvmTransactionCurrency([first, second], token(secondContract), 1), same(second));
  });
  test('contract matching is case insensitive without changing the selected object', () {
    final cached = token(firstContract);
    expect(resolveEvmTransactionCurrency([cached], token('0x${'A' * 40}'), 1), same(cached));
  });
  test('explicit foreign-chain token is rejected', () {
    expect(() => resolveEvmTransactionCurrency([token(firstContract)], token(firstContract, chain: 137), 1),
        throwsA(isA<EVMChainTransactionCreationException>()));
  });
  test('foreign-chain cached token is not selected by a legacy request', () {
    expect(() => resolveEvmTransactionCurrency([token(firstContract, chain: 137)], token(firstContract, chain: null), 1),
        throwsA(isA<EVMChainTransactionCreationException>()));
  });
  test('different decimals cannot silently reinterpret the amount', () {
    expect(() => resolveEvmTransactionCurrency([token(firstContract)], token(firstContract, decimals: 18), 1),
        throwsA(isA<EVMChainTransactionCreationException>()));
  });
  test('duplicate matching contracts are ambiguous, even when symbols agree', () {
    expect(() => resolveEvmTransactionCurrency([token(firstContract), token(firstContract)], token(firstContract), 1),
        throwsA(isA<EVMChainTransactionCreationException>()));
  });
  test('malformed contract is rejected before signing', () {
    expect(() => resolveEvmTransactionCurrency([token('not-an-address')], token('not-an-address'), 1),
        throwsA(isA<EVMChainTransactionCreationException>()));
  });
  test('native ETH cannot select a same-titled ERC20 token', () {
    final impostor = Erc20Token(name: 'Ether', symbol: 'ETH', contractAddress: firstContract, decimal: 18);
    expect(resolveEvmTransactionCurrency([impostor, CryptoCurrency.eth], CryptoCurrency.eth, 1), CryptoCurrency.eth);
  });

  EVMChainTransactionCredentials transfer({String? memo, int amount = 1}) =>
      EVMChainTransactionCredentials([OutputInfo(
        address: '0x0000000000000000000000000000000000000002',
        sendAll: false, isParsedAddress: false,
        cryptoAmount: Money.fromInt(amount, CryptoCurrency.eth), memo: memo,
      )], priority: null, currency: CryptoCurrency.eth);

  test('network change during fee RPC prevents signing on a different chain', () async {
    final wallet = _FeeControlledWallet(info);
    addTearDown(wallet.close);
    final rejected = expectLater(wallet.createTransaction(transfer()),
        throwsA(isA<EVMChainTransactionCreationException>()));
    await wallet.feeStarted.future;
    await wallet.selectChain(137, node: Node(uri: 'fixture.invalid', type: WalletType.ethereum, useSSL: true));
    wallet.feeResult.complete(GasParamsHandler.zero());
    await rejected;
  });
  test('closing during fee RPC prevents use of released wallet state', () async {
    final wallet = _FeeControlledWallet(info);
    final rejected = expectLater(wallet.createTransaction(transfer()),
        throwsA(isA<EVMChainTransactionCreationException>()));
    await wallet.feeStarted.future;
    await wallet.close();
    wallet.feeResult.complete(GasParamsHandler.zero());
    await rejected;
  });
  test('negative native amount is rejected before fee RPC or signing', () async {
    final wallet = _FeeControlledWallet(info);
    addTearDown(wallet.close);
    await expectLater(wallet.createTransaction(transfer(amount: -1)),
        throwsA(isA<EVMChainTransactionCreationException>()));
    expect(wallet.feeStarted.isCompleted, isFalse);
  });
  test('memo gas estimation receives the exact UTF-8 bytes, not UTF-16 code units', () async {
    final wallet = _FeeControlledWallet(info);
    addTearDown(wallet.close);
    const memo = 'Pagamento em português — café 🧪';
    final stopped = expectLater(wallet.createTransaction(transfer(memo: memo)), throwsStateError);
    await wallet.feeStarted.future;
    expect(wallet.estimatedData, utf8.encode(memo));
    wallet.feeResult.completeError(StateError('stop fixture before signing'));
    await stopped;
  });
}
