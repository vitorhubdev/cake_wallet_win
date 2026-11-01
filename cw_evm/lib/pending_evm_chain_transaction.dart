import 'dart:async';
import 'dart:typed_data';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:web3dart/crypto.dart';
import 'package:hex/hex.dart' as Hex;

class PendingEVMChainTransaction with PendingTransaction {
  final Function sendTransaction;
  final Uint8List signedTransaction;
  final bool isInfiniteApproval;

  PendingEVMChainTransaction({
    required this.sendTransaction,
    required Uint8List signedTransaction,
    required this.fee,
    required this.amount,
    this.isInfiniteApproval = false,
  }) : signedTransaction = Uint8List.fromList(signedTransaction).asUnmodifiableView();

  @override
  String get amountFormatted {
    if (isInfiniteApproval) return "∞";
    return amount.toString();
  }

  @override
  final Money amount;

  @override
  final Money fee;

  @override
  Future<void> commit() {
    final pending = _commitInFlight;
    if (pending != null) return pending;
    // Retain successful completion: repeated clicks never rebroadcast this object.
    // A failure is surfaced, not automatically retried. Only a new explicit call
    // may retry the same signed transaction (and therefore the same nonce/hash).
    late final Future<void> operation;
    operation = Future<void>.sync(() async { await sendTransaction(); }).then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (identical(_commitInFlight, operation)) _commitInFlight = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _commitInFlight = operation;
    return operation;
  }

  Future<void>? _commitInFlight;

  @override
  String get feeFormatted => fee.toStringWithSymbol(fractionalDigits: 10);

  @override
  String get feeFormattedValue => fee.toStringWithPrecision(fractionalDigits: 10);

  @override
  String get hex => bytesToHex(signedTransaction, include0x: true);

  @override
  String get id => '0x${Hex.HEX.encode(keccak256(signedTransaction))}';

  @override
  String? get evmTxHashFromRawHex => id;

  @override
  Future<Map<String, String>> commitUR() => throw UnimplementedError();
}
