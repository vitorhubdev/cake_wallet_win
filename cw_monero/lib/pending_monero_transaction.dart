import 'package:cw_core/utils/submission_gate.dart';

import 'dart:async';
import 'dart:ffi';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_monero/api/account_list.dart';
import 'package:cw_monero/api/structs/pending_transaction.dart';
import 'package:cw_monero/api/transaction_history.dart' as monero_transaction_history;
import 'package:cw_monero/api/wallet.dart';
import 'package:cw_monero/monero_wallet.dart';
import 'package:monero/monero.dart' as monero;

class DoubleSpendException implements Exception {
  DoubleSpendException();

  @override
  String toString() =>
      'This transaction cannot be committed. This can be due to many reasons including the wallet not being synced, there is not enough XMR in your available balance, or previous transactions are not yet fully processed.';
}

class PendingMoneroTransaction with PendingTransaction {
  PendingMoneroTransaction(this.pendingTransactionDescription, this.wallet);

  final PendingTransactionDescription pendingTransactionDescription;
  final MoneroWalletBase wallet;
  final _submission = SubmissionGate<Object?>();

  void _requireActiveWallet() {
    if (!wallet.isActiveNativeSession) {
      throw StateError('The active Monero wallet changed. Review the transaction before sending.');
    }
  }

  void _refreshAfterSubmission() {
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!wallet.isActiveNativeSession) return;
      try {
        await wallet.fetchTransactions();
      } catch (_) {
        printV('Monero transaction refresh failed after submission.');
      }
    }());
  }

  Money get amount => Money.fromInt(pendingTransactionDescription.amount, CryptoCurrency.xmr);

  Money get fee => Money.fromInt(pendingTransactionDescription.fee, CryptoCurrency.xmr);

  @override
  String get id => pendingTransactionDescription.hash;

  @override
  String get hex => pendingTransactionDescription.hex;

  @override
  String get amountFormatted => amount.toString();

  @override
  bool shouldCommitUR() => isViewOnly && wallet.hardwareWalletType != HardwareWalletType.trezor;

  @override
  Future<void> commit() async {
    await _submission.run('broadcast', () async {
      await _commitOnce();
      return null;
    });
  }

  Future<void> _commitOnce() async {
    _requireActiveWallet();
    if (wallet.hardwareWalletType == HardwareWalletType.trezor) {
      final ptr = Pointer<Void>.fromAddress(pendingTransactionDescription.pointerAddress);
      final ret = await monero.PendingTransaction_commitTrezor(ptr, 0);

      final json = await wallet.signTrezorTransaction(ret);

      await walletStoreQueue.run(() async {
        _requireActiveWallet();
        final wptr = Pointer<Void>.fromAddress(currentWallet!.ffiAddress());
        final success = monero.Wallet_submitTransactionHex(wptr, json);
        if (!success) {
          // This is a Wallet error. The previous code treated a PendingTransaction
          // pointer as an UnsignedTransaction pointer, which is not a valid ABI cast.
          throw StateError(monero.Wallet_errorString(wptr));
        }
      });
    } else {
      try {
        await monero_transaction_history.commitTransactionFromPointerAddress(
          address: pendingTransactionDescription.pointerAddress,
          useUR: false,
        );
      } catch (e) {
        final message = e.toString();

        if (message.contains('Reason: double spend')) {
          throw DoubleSpendException();
        }

        rethrow;
      }
    }
    if (wallet.isActiveNativeSession) await storeInBackground(force: true);
    _refreshAfterSubmission();
  }

  @override
  Future<Map<String, String>> commitUR() async {
    final result = await _submission.run('ur', () => _commitUROnce());
    return Map<String, String>.from(result! as Map<String, String>);
  }

  Future<Map<String, String>> _commitUROnce() async {
    _requireActiveWallet();
    try {
      final ret = await monero_transaction_history.commitTransactionFromPointerAddress(
        address: pendingTransactionDescription.pointerAddress,
        useUR: true,
      );
      if (wallet.isActiveNativeSession) await storeInBackground(force: true);
      _refreshAfterSubmission();
      if (ret == null) return {};
      return {"xmr-txsigned": ret};
    } catch (e) {
      final message = e.toString();

      if (message.contains('Reason: double spend')) {
        throw DoubleSpendException();
      }

      rethrow;
    }
  }
}
