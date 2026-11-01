import 'dart:async';
import 'dart:typed_data';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_evm/pending_evm_chain_transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/crypto.dart';

PendingEVMChainTransaction transaction(Uint8List bytes, Function send) =>
    PendingEVMChainTransaction(
      signedTransaction: bytes,
      sendTransaction: send,
      amount: Money.zero(CryptoCurrency.eth),
      fee: Money.zero(CryptoCurrency.eth),
    );

void main() {
  // These are serialization/hash fixtures, not signed mainnet payments.
  for (final fixture in <String, List<int>>{
    'legacy envelope': [0xc9, 0x80, 1, 0x82, 0x52, 8, 0x80, 0x80, 0x80, 0x80],
    'type 1 envelope': [1, 0xc0],
    'type 2 envelope': [2, 0xc0],
    'type 3 envelope': [3, 0xc0],
    'type 4 envelope': [4, 0xc0],
  }.entries) {
    test('${fixture.key}: id hashes the exact serialized bytes without another prefix', () {
      final bytes = Uint8List.fromList(fixture.value);
      final pending = transaction(bytes, () async {});
      final expected = bytesToHex(keccak256(bytes), include0x: true);
      expect(pending.id, expected);
      expect(pending.evmTxHashFromRawHex, expected);
      expect(pending.hex, bytesToHex(bytes, include0x: true));
    });
  }

  test('known Keccak-256 byte vector', () {
    final pending = transaction(Uint8List.fromList([97, 98, 99]), () async {});
    expect(pending.id,
        '0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
  });

  test('caller buffer mutation cannot change the confirmed identity', () {
    final bytes = Uint8List.fromList([2, 0xc0]);
    final pending = transaction(bytes, () async {});
    final before = pending.id;
    bytes[0] = 1;
    expect(pending.id, before);
    expect(() => pending.signedTransaction[0] = 1, throwsUnsupportedError);
  });

  test('50 simultaneous commits share one broadcast', () async {
    final hold = Completer<void>();
    var broadcasts = 0;
    final pending = transaction(Uint8List.fromList([2, 0xc0]), () async {
      broadcasts++;
      await hold.future;
    });
    final commits = List.generate(50, (_) => pending.commit());
    expect(commits.every((f) => identical(f, commits.first)), isTrue);
    expect(broadcasts, 1);
    hold.complete();
    await Future.wait(commits);
    await pending.commit();
    expect(broadcasts, 1);
  });

  test('a failed broadcast is surfaced, not retried automatically', () async {
    var broadcasts = 0;
    final pending = transaction(Uint8List.fromList([2, 0xc0]), () async {
      if (++broadcasts == 1) throw StateError('synthetic RPC failure');
    });
    await expectLater(pending.commit(), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(broadcasts, 1);
    await pending.commit();
    await pending.commit();
    expect(broadcasts, 2);
  });

  test('synchronous broadcaster failure does not poison explicit retries', () async {
    var broadcasts = 0;
    final pending = transaction(Uint8List.fromList([2, 0xc0]), () {
      if (++broadcasts == 1) throw StateError('synthetic synchronous failure');
      return Future<void>.value();
    });
    await expectLater(pending.commit(), throwsStateError);
    await pending.commit();
    expect(broadcasts, 2);
  });
}
