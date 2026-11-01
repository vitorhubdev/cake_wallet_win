import 'dart:convert';
import 'dart:core';
import 'dart:developer';
import 'package:cw_core/encryption_file_utils.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/utils/async_serial_queue.dart';
import 'package:cw_evm/evm_chain_transaction_info.dart';
import 'package:cw_evm/utils/evm_chain_utils.dart';
import 'package:mobx/mobx.dart';
import 'package:cw_core/transaction_history.dart';

part 'evm_chain_transaction_history.g.dart';

class EVMChainTransactionHistory = EVMChainTransactionHistoryBase with _$EVMChainTransactionHistory;

abstract class EVMChainTransactionHistoryBase
    extends TransactionHistoryBase<EVMChainTransactionInfo> with Store {
  EVMChainTransactionHistoryBase({
    required this.walletInfo,
    required String password,
    required this.encryptionFileUtils,
    required this.getCurrentChainId,
    this.directoryResolver,
  }) : _password = password {
    transactions = ObservableMap<String, EVMChainTransactionInfo>();
  }

  final String _password;
  final Future<String> Function()? directoryResolver;
  final AsyncSerialQueue _writes = AsyncSerialQueue();
  int _loadGeneration = 0;

  Future<String> _directory() => directoryResolver?.call() ??
      pathForWalletDir(name: walletInfo.name, type: walletInfo.type);

  final WalletInfo walletInfo;
  final EncryptionFileUtils encryptionFileUtils;

  /// Function to get the current chain ID (allows transaction history to use correct file)
  final int Function() getCurrentChainId;

  /// Get transaction history file name based on current chain ID
  String getTransactionHistoryFileName() {
    return EVMChainUtils.getTransactionHistoryFileName(getCurrentChainId());
  }

  EVMChainTransactionInfo getTransactionInfo(Map<String, dynamic> val) {
    return EVMChainTransactionInfo.fromJson(val, getCurrentChainId());
  }

  Future<void> init() async {
    final generation = ++_loadGeneration;
    final chainId = getCurrentChainId();
    clear();
    await _writes.idle;
    if (generation != _loadGeneration || chainId != getCurrentChainId()) return;
    await _load(chainId, generation);
  }

  @override
  Future<void> save() {
    // Snapshot before the first await. Otherwise a network switch can pair an
    // old filename with the new network's transactions, destroying history.
    final chainId = getCurrentChainId();
    final filename = EVMChainUtils.getTransactionHistoryFileName(chainId);
    final data = json.encode({'transactions': {
      for (final entry in transactions.entries)
        if (entry.value.chainId == chainId) entry.key: entry.value.toJson(),
    }});
    return _writes.run(() async {
      final dirPath = await _directory();
      await encryptionFileUtils.write(
        path: '$dirPath/$filename', password: _password, data: data);
    });
  }

  @override
  void addOne(EVMChainTransactionInfo transaction) {
    if (transaction.chainId == getCurrentChainId()) {
      transactions[transaction.id] = transaction;
    }
  }

  @override
  void addMany(Map<String, EVMChainTransactionInfo> transactionsToAdd) {
    final currentChainId = getCurrentChainId();

    // First, remove any transactions that don't match the current chainId
    // This prevents transactions from other chains from persisting in the map
    transactions.removeWhere((key, value) => value.chainId != currentChainId);

    // Then add/update transactions for the current chain
    for (final entry in transactionsToAdd.entries) {
      if (entry.value.chainId == currentChainId) {
        transactions[entry.key] = entry.value;
      }
    }
  }

  Future<Map<String, dynamic>> _read(int chainId) async {
    final filename = EVMChainUtils.getTransactionHistoryFileName(chainId);
    final dirPath = await _directory();
    final content = await encryptionFileUtils.read(
      path: '$dirPath/$filename', password: _password);
    if (content.isEmpty) return {};
    return json.decode(content) as Map<String, dynamic>;
  }

  Future<void> _load(int chainId, int generation) async {
    try {
      final content = await _read(chainId);
      if (generation != _loadGeneration || chainId != getCurrentChainId()) return;
      final txs = content['transactions'] as Map<String, dynamic>? ?? {};
      for (final val in txs.values) {
        if (val is! Map<String, dynamic>) continue;
        // Older history did not record a chain id. Explicit mismatches must not
        // be silently relabelled as transactions of the currently selected chain.
        final storedChain = val['chainId'];
        if (storedChain != null && storedChain != chainId) continue;
        try {
          final tx = EVMChainTransactionInfo.fromJson(val, chainId);
          transactions[tx.id] = tx;
        } catch (_) {
          // One malformed row must not hide all remaining valid transactions.
          log('Skipped a malformed EVM transaction history row.');
        }
      }
    } catch (_) {
      log('Could not read EVM transaction history.');
    }
  }
}
