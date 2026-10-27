import 'dart:async';

import 'package:cake_wallet/reactions/wallet_connect.dart';
import 'package:cake_wallet/utils/tor.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/evm/evm.dart';

Timer? _checkConnectionTimer;
int _connectionCheckGeneration = 0;
const _nodeProbeTimeout = Duration(seconds: 10);

void stopCheckConnectionReaction() {
  _connectionCheckGeneration++;
  _checkConnectionTimer?.cancel();
  _checkConnectionTimer = null;
}

void startCheckConnectionReaction(WalletBase wallet, SettingsStore settingsStore,
    {int timeInterval = 5, required bool Function() isCurrentWallet}) {
  stopCheckConnectionReaction();
  final generation = _connectionCheckGeneration;
  var isChecking = false;
  bool isActive() => generation == _connectionCheckGeneration && isCurrentWallet();

  _checkConnectionTimer = Timer.periodic(Duration(seconds: timeInterval), (_) async {
    // A slow node must not start another probe/connection every five seconds.
    if (!isActive() || isChecking || wallet.syncStatus is ConnectingSyncStatus) return;
    if (wallet.type == WalletType.bitcoin && wallet.syncStatus is SyncingSyncStatus) {
      return;
    }
    if (wallet.type == WalletType.decred && wallet.syncStatus is ProcessingSyncStatus) {
      return;
    }

    isChecking = true;
    try {
      final connectivityResult = await (Connectivity().checkConnectivity());
      if (!isActive()) return;

      int? chainId;
      if (isEVMCompatibleChain(wallet.type)) {
        chainId = evm!.getSelectedChainId(wallet);
      }

      final node = settingsStore.getCurrentNode(wallet.type, chainId: chainId);
      bool isCurrentRequest() {
        if (!isActive()) return false;
        if (isEVMCompatibleChain(wallet.type) && evm!.getSelectedChainId(wallet) != chainId) {
          return false;
        }
        return settingsStore.getCurrentNode(wallet.type, chainId: chainId) == node;
      }

      Future<bool> probeNode() =>
          node.requestNode().timeout(_nodeProbeTimeout, onTimeout: () => false);
      bool? reachable;

      if (connectivityResult.contains(ConnectivityResult.none)) {
        // Still try node even when OS says no network - it might be a LAN node.
        reachable = await probeNode();
        if (!isCurrentRequest()) return;
        if (!reachable) {
          wallet.syncStatus = FailedSyncStatus();
          return;
        }
      }

      if (wallet.type != WalletType.bitcoin &&
          (wallet.syncStatus is LostConnectionSyncStatus ||
              wallet.syncStatus is FailedSyncStatus)) {
        final alive = reachable ?? await probeNode();
        if (!isCurrentRequest()) return;

        if (alive) {
          if (settingsStore.currentBuiltinTor) {
            await ensureTorStarted(context: null);
          }

          // Manual reconnect or a node change may have completed while the
          // probe/Tor bootstrap was pending. Never reinitialize that session.
          if (isCurrentRequest() &&
              (wallet.syncStatus is LostConnectionSyncStatus ||
                  wallet.syncStatus is FailedSyncStatus)) {
            await wallet.connectToNode(node: node);
          }
        }
      }
    } catch (e) {
      printV(e.toString());
    } finally {
      isChecking = false;
    }
  });
}
