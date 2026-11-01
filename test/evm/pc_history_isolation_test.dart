import 'dart:async';
import 'dart:convert';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_evm/evm_chain_transaction_history.dart';
import 'package:cw_evm/evm_chain_transaction_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Info extends Mock implements WalletInfo {}
class _Files extends EncryptionFileUtils {
  final writes = <String, String>{};
  final reads = <String, Completer<String>>{};
  Completer<void>? writeGate;
  int activeWrites = 0;
  int maxActiveWrites = 0;
  bool failNext = false;
  @override
  Future<void> write({required String path, required String password, required String data}) async {
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    try {
      if (writeGate != null) await writeGate!.future;
      if (failNext) { failNext = false; throw StateError('synthetic write failure'); }
      writes[path] = data;
    } finally { activeWrites--; }
  }
  @override
  Future<String> read({required String path, required String password}) =>
      reads.putIfAbsent(path, Completer<String>.new).future;
}

EVMChainTransactionInfo tx(int chain, String id) => EVMChainTransactionInfo(
  id: id, height: 1, amount: Money.fromInt(1, CryptoCurrency.eth),
  fee: Money.zero(CryptoCurrency.eth), tokenSymbol: 'ETH',
  direction: TransactionDirection.incoming, isPending: false,
  date: DateTime.utc(2020), confirmations: 1, to: null, from: null, chainId: chain,
);
String history(List<EVMChainTransactionInfo> transactions) => jsonEncode({
  'transactions': {for (final item in transactions) item.id: item.toJson()},
});
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  late _Files files;
  late _Info info;
  late EVMChainTransactionHistory store;
  late int chain;
  setUp(() {
    chain = 1;
    files = _Files();
    info = _Info();
    when(() => info.name).thenReturn('unfunded-fixture');
    when(() => info.type).thenReturn(WalletType.ethereum);
    store = EVMChainTransactionHistory(walletInfo: info, password: 'test-only',
      encryptionFileUtils: files, getCurrentChainId: () => chain,
      directoryResolver: () async => '/fixture');
  });

  test('save freezes the chain and its data before resolving the directory', () async {
    final directory = Completer<String>();
    store = EVMChainTransactionHistory(walletInfo: info, password: 'test-only',
      encryptionFileUtils: files, getCurrentChainId: () => chain,
      directoryResolver: () => directory.future);
    store.addOne(tx(1, 'ethereum'));
    final saved = store.save();
    chain = 137;
    store.clear();
    store.addOne(tx(137, 'polygon'));
    directory.complete('/fixture');
    await saved;
    final data = jsonDecode(files.writes['/fixture/transactions.json']!);
    expect((data['transactions'] as Map).keys, ['ethereum']);
    expect(files.writes.containsKey('/fixture/polygon_transactions.json'), isFalse);
  });
  test('50 saves never overlap encrypted writes', () async {
    files.writeGate = Completer<void>();
    store.addOne(tx(1, 'ethereum'));
    final pending = List.generate(50, (_) => store.save());
    await tick();
    expect(files.activeWrites, 1);
    files.writeGate!.complete();
    await Future.wait(pending);
    expect(files.maxActiveWrites, 1);
  });
  test('a failed save reaches its caller without poisoning the queue', () async {
    files.failNext = true;
    await expectLater(store.save(), throwsStateError);
    store.addOne(tx(1, 'newer'));
    await store.save();
    expect(files.writes['/fixture/transactions.json'], contains('newer'));
  });
  test('a delayed old network read cannot replace the new history', () async {
    final ethereum = store.init();
    await tick();
    chain = 137;
    final polygon = store.init();
    await tick();
    files.reads['/fixture/polygon_transactions.json']!.complete(history([tx(137, 'polygon')]));
    await polygon;
    files.reads['/fixture/transactions.json']!.complete(history([tx(1, 'ethereum')]));
    await ethereum;
    expect(store.transactions.keys, ['polygon']);
    expect(store.transactions.values.single.chainId, 137);
  });
  test('explicitly foreign rows are not relabelled as Ethereum', () async {
    final loaded = store.init();
    await tick();
    files.reads['/fixture/transactions.json']!.complete(history([tx(137, 'foreign'), tx(1, 'ethereum')]));
    await loaded;
    expect(store.transactions.keys, ['ethereum']);
  });
  test('legacy rows without chainId retain file-based compatibility', () async {
    final data = tx(1, 'legacy').toJson()..remove('chainId');
    final loaded = store.init();
    await tick();
    files.reads['/fixture/transactions.json']!.complete(jsonEncode({'transactions': {'legacy': data}}));
    await loaded;
    expect(store.transactions.values.single.chainId, 1);
  });
  test('a malformed row does not hide subsequent valid rows', () async {
    final loaded = store.init();
    await tick();
    files.reads['/fixture/transactions.json']!.complete(jsonEncode({'transactions': {
      'broken': {'id': 'broken'}, 'valid': tx(1, 'valid').toJson(),
    }}));
    await loaded;
    expect(store.transactions.keys, ['valid']);
  });
  test('a read failure does not invent transactions or overwrite a file', () async {
    final loaded = store.init();
    await tick();
    files.reads['/fixture/transactions.json']!.completeError(StateError('synthetic read failure'));
    await loaded;
    expect(store.transactions, isEmpty);
    expect(files.writes, isEmpty);
  });
  test('addMany rejects foreign chain records', () {
    store.addMany({'foreign': tx(137, 'foreign'), 'ethereum': tx(1, 'ethereum')});
    expect(store.transactions.keys, ['ethereum']);
  });
}
