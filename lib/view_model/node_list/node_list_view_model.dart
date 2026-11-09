import 'dart:math';

import 'package:cw_core/monero_node_health.dart';
import 'package:cake_wallet/utils/node_display_address.dart';

import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/store/app_store.dart';
import "package:cw_core/exceptions/cake_exception.dart";
import 'package:cw_core/node_list.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_core/utils/proxy_wrapper.dart';
import 'package:mobx/mobx.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cw_core/node.dart';
import 'package:cake_wallet/entities/default_settings_migration.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/reactions/wallet_connect.dart';

part 'node_list_view_model.g.dart';

class NodeSpeed {
  final String iconPath;
  final String darkIconPath;

  // fraction of best node ping needed to be classified as this speed.
  final double treshold;

  const NodeSpeed._(this.iconPath, this.darkIconPath, this.treshold);

  static const disconnected = NodeSpeed._(
    "assets/new-ui/node_speed_badges/disconnected.svg",
    "assets/new-ui/node_speed_badges/disconnected-dark.svg",
    0,
  );
  static const slow = NodeSpeed._(
    "assets/new-ui/node_speed_badges/slow.svg",
    "assets/new-ui/node_speed_badges/slow-dark.svg",
    0,
  );
  static const medium = NodeSpeed._(
    "assets/new-ui/node_speed_badges/medium.svg",
    "assets/new-ui/node_speed_badges/medium.svg",
    0.5,
  );
  static const fast = NodeSpeed._(
    "assets/new-ui/node_speed_badges/fast.svg",
    "assets/new-ui/node_speed_badges/fast.svg",
    0.8,
  );

  static const all = [fast, medium, slow, disconnected];
}

class NodeListViewModel = NodeListViewModelBase with _$NodeListViewModel;

abstract class NodeListViewModelBase with Store {
  NodeListViewModelBase(this._appStore, this.isPow)
    : nodes = ObservableList<Node>(),
      _nodeSpeeds = ObservableMap<String, int>(),
      settingsStore = _appStore.settingsStore {
    bindNodes();

    reaction((_) => _appStore.wallet, (WalletBase? _wallet) {
      bindNodes();
    });

    reaction(
      (_) {
        final wallet = _appStore.wallet;
        if (wallet != null && isEVMCompatibleChain(wallet.type)) {
          // Access selectedChainId to track changes
          return evm!.getSelectedChainId(wallet);
        }
        return null;
      },
      (_) {
        bindNodes();
      },
    );
  }

  @computed
  Node get currentNode {
    final wallet = _appStore.wallet!;
    final walletType = wallet.type;

    int? chainId;
    if (isEVMCompatibleChain(walletType)) {
      chainId = evm!.getSelectedChainId(wallet);
    }

    if (isEVMCompatibleChain(walletType) && chainId != null) {
      return settingsStore.getCurrentNode(walletType, chainId: chainId);
    }

    final node = isPow ? settingsStore.powNodes[walletType] : settingsStore.nodes[walletType];
    if (node == null) {
      throw NodeLookupException('No node for wallet type: $walletType');
    }
    return node;
  }

  String getAlertContent(String uri) =>
      S.current.change_current_node(uri) +
      '${uri.endsWith('.onion') || uri.contains('.onion:') ? '\n' + (CakeTor.instance!.enabled ? '' : S.current.orbot_running_alert) : ''}';

  @computed
  bool get enableAutomaticNodeSwitching => settingsStore.enableAutomaticNodeSwitching;

  @action
  void setEnableAutomaticNodeSwitching(bool value) =>
      settingsStore.enableAutomaticNodeSwitching = value;

  final ObservableList<Node> nodes;
  final SettingsStore settingsStore;
  final AppStore _appStore;
  final bool isPow;
  final ObservableMap<String, int> _nodeSpeeds;
  final _nodeHealth = ObservableMap<String, MoneroNodeHealth>();
  final Set<String> _testedNodes = {};
  int _testGeneration = 0;
  int _bindGeneration = 0;
  MoneroProbeCancellation? _probeCancellation;
  String _nodeKey(Node node) => node.healthIdentity;

  MoneroNodeHealth? healthFor(Node node) => _nodeHealth[_nodeKey(node)];
  int? latencyFor(Node node) => healthFor(node)?.latencyMs ?? _nodeSpeeds[_nodeKey(node)];

  void cancelSpeedTest() {
    _testGeneration++;
    _probeCancellation?.cancel();
    _probeCancellation = null;
    isTestingNodeSpeed = false;
  }

  @computed
  List<Node> get nonCurrentNodes {
    final result = nodes.where((item) => item != currentNode).toList();
    if (_appStore.wallet?.type == WalletType.monero) {
      // A responsive unsynchronized daemon must not outrank a ready daemon
      // solely because its HTTP reply is faster. Selection remains manual.
      final order = {for (var i = 0; i < result.length; i++) result[i].id: i};
      result.sort((a, b) {
        final comparison = MoneroNodeHealth.compare(healthFor(a), healthFor(b));
        return comparison != 0 ? comparison : (order[a.id] ?? 0).compareTo(order[b.id] ?? 0);
      });
    }
    return result;
  }

  @observable
  bool isTestingNodeSpeed = false;

  Future<void> speedTestNodes() async {
    if (isTestingNodeSpeed) return;
    final wallet = _appStore.wallet;
    if (wallet == null) return;
    final generation = ++_testGeneration;
    final cancellation = MoneroProbeCancellation();
    _probeCancellation = cancellation;
    bool active() => generation == _testGeneration && identical(wallet, _appStore.wallet);
    final snapshot = nodes.map((node) => Node.fromMap(node.toMap())).toList();
    isTestingNodeSpeed = true;
    _nodeSpeeds.clear();
    _testedNodes.clear();
    var cursor = 0;
    Future<void> worker() async {
      while (active() && cursor < snapshot.length) {
        final node = snapshot[cursor++];
        final key = _nodeKey(node);
        if (node.type == WalletType.monero) {
          final previous = _nodeHealth[key];
          final cooldown = previous?.retryAfter;
          if (previous != null &&
              cooldown != null &&
              DateTime.now().isBefore(previous.checkedAt.add(cooldown)))
            continue;
          final result = await node.probeMoneroHealth(
            expectedNetwork: wallet.isTestnet ? 'testnet' : 'mainnet',
            cancellation: cancellation,
          );
          if (!active() ||
              key != _nodeKey(node) ||
              !nodes.any((current) => _nodeKey(current) == key))
            continue;
          _nodeHealth[key] = result;
          _testedNodes.add(key);
          if (result.ready && result.latencyMs != null) _nodeSpeeds[key] = result.latencyMs!;
        } else {
          final sw = Stopwatch()..start();
          var ok = false;
          try {
            ok = await node.requestNode().timeout(const Duration(seconds: 10));
          } catch (_) {}
          if (!active() || key != _nodeKey(node)) continue;
          _testedNodes.add(key);
          if (ok) _nodeSpeeds[key] = max(1, sw.elapsedMilliseconds);
        }
      }
    }

    try {
      // Bound sockets and daemon load; repeated clicks join the visible run.
      await Future.wait(List.generate(min(3, snapshot.length), (_) => worker()));
    } finally {
      if (generation == _testGeneration) {
        _probeCancellation = null;
        isTestingNodeSpeed = false;
      }
    }
  }

  NodeSpeed? nodeSpeedFor(Node node) {
    final bestSpeed = _bestNodeSpeed;
    final currentSpeed = _nodeSpeeds[_nodeKey(node)];
    if (bestSpeed == null) {
      return _testedNodes.contains(_nodeKey(node)) ? NodeSpeed.disconnected : null;
    }
    if (currentSpeed == null) {
      return NodeSpeed.disconnected;
    }
    for (final speed in NodeSpeed.all) {
      if (currentSpeed < (bestSpeed / speed.treshold)) return speed;
    }

    return null;
  }

  int? get _bestNodeSpeed {
    try {
      return _nodeSpeeds.values.reduce(min);
    } catch (e) {}
    return null;
  }

  Future<void> reset() async {
    await resetToDefault();

    final wallet = _appStore.wallet!;
    final walletType = wallet.type;

    Node node;
    if (walletType == WalletType.bitcoin && wallet.isTestnet) {
      node = (await getBitcoinTestnetDefaultElectrumServer())!;
    } else if (isEVMCompatibleChain(walletType)) {
      final chainId = evm!.getSelectedChainId(wallet);
      if (chainId != null) {
        final nodeWalletType = evm!.getWalletTypeByChainId(chainId);
        if (nodeWalletType != null) {
          node = (await Node.getDefaultForWalletType(nodeWalletType))!;
        } else {
          throw BadChainIdException(
            'Cannot reset node for EVM wallet: wallet type not found for chainId: $chainId',
          );
        }
      } else {
        throw BadChainIdException('Cannot reset node for EVM wallet: chainId is null');
      }
    } else {
      node = (await Node.getDefaultForWalletType(_appStore.wallet!.type))!;
    }

    await setAsCurrent(node);
  }

  @action
  Future<void> delete(Node node) async => node.delete();

  @action
  Future<void> setAsCurrent(Node node) async {
    final wallet = _appStore.wallet!;
    final walletType = wallet.type;

    if (isEVMCompatibleChain(walletType)) {
      final chainId = evm!.getSelectedChainId(wallet);
      if (chainId != null) {
        final nodeWalletType = evm!.getWalletTypeByChainId(chainId);
        if (nodeWalletType != null) {
          settingsStore.nodes[nodeWalletType] = node;
          return;
        }
      }
      throw BadChainIdException('Cannot set node for EVM wallet: chainId or wallet type not found');
    }

    // For non-EVM wallets, use the wallet type directly
    if (isPow) {
      settingsStore.powNodes[walletType] = node;
    } else {
      settingsStore.nodes[walletType] = node;
    }
  }

  @action
  Future<void> bindNodes() async {
    cancelSpeedTest();
    final generation = ++_bindGeneration;
    nodes.clear();
    _nodeSpeeds.clear();
    _nodeHealth.clear();
    _testedNodes.clear();
    final wallet = _appStore.wallet;
    if (wallet == null) return;
    final walletType = wallet.type;
    List<Node> fetched;
    if (isEVMCompatibleChain(walletType)) {
      final chainId = evm!.getSelectedChainId(wallet);
      final nodeWalletType = chainId == null ? null : evm!.getWalletTypeByChainId(chainId);
      if (nodeWalletType == null) return;
      fetched = await Node.getAllForWalletType(nodeWalletType);
      if (evm!.getSelectedChainId(wallet) != chainId) return;
    } else {
      fetched = isPow
          ? await Node.getAllForWalletTypePow(walletType)
          : await Node.getAllForWalletType(walletType);
    }
    if (generation == _bindGeneration && identical(wallet, _appStore.wallet)) {
      nodes.addAll(fetched);
    }
  }
}
