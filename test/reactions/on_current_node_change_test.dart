import 'package:cake_wallet/reactions/on_current_node_change.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';
import 'package:mocktail/mocktail.dart';

class _MockAppStore extends Mock implements AppStore {}

class _MockSettingsStore extends Mock implements SettingsStore {}

class _MockWallet extends Mock
    implements WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {}

void main() {
  late _MockAppStore appStore;
  late _MockSettingsStore settings;
  late _MockWallet wallet;
  late ObservableMap<WalletType, Node> nodes;
  late ObservableMap<WalletType, Node> powNodes;

  setUpAll(() {
    registerFallbackValue(Node(uri: 'unused.example:18081', type: WalletType.monero));
  });

  setUp(() {
    appStore = _MockAppStore();
    settings = _MockSettingsStore();
    wallet = _MockWallet();
    nodes = ObservableMap<WalletType, Node>();
    powNodes = ObservableMap<WalletType, Node>();
    when(() => appStore.wallet).thenReturn(wallet);
    when(() => appStore.settingsStore).thenReturn(settings);
    when(() => settings.nodes).thenReturn(nodes);
    when(() => settings.powNodes).thenReturn(powNodes);
    when(() => wallet.type).thenReturn(WalletType.monero);
    when(() => wallet.connectToNode(node: any(named: 'node'))).thenAnswer((_) async {});
    when(() => wallet.connectToPowNode(node: any(named: 'node'))).thenAnswer((_) async {});
  });

  test('rebootstrapping observes a Monero node change exactly once', () async {
    startOnCurrentNodeChangeReaction(appStore);
    startOnCurrentNodeChangeReaction(appStore);
    final node = Node(uri: 'monero.example:18081', type: WalletType.monero);

    nodes[WalletType.monero] = node;
    await Future<void>.delayed(Duration.zero);

    verify(() => wallet.connectToNode(node: node)).called(1);
  });

  test('rebootstrapping also replaces the proof of work observer', () async {
    when(() => wallet.type).thenReturn(WalletType.nano);
    startOnCurrentNodeChangeReaction(appStore);
    startOnCurrentNodeChangeReaction(appStore);
    final node = Node(uri: 'nano.example', type: WalletType.nano, isPow: true);

    powNodes[WalletType.nano] = node;
    await Future<void>.delayed(Duration.zero);

    verify(() => wallet.connectToPowNode(node: node)).called(1);
  });

  test('a node for another currency does not reconnect the current wallet', () async {
    startOnCurrentNodeChangeReaction(appStore);
    nodes[WalletType.bitcoin] = Node(uri: 'bitcoin.example:50002', type: WalletType.bitcoin);
    await Future<void>.delayed(Duration.zero);

    verifyNever(() => wallet.connectToNode(node: any(named: 'node')));
  });

  test('updates after logout do not connect the previous wallet', () async {
    startOnCurrentNodeChangeReaction(appStore);
    when(() => appStore.wallet).thenReturn(null);
    nodes[WalletType.monero] = Node(uri: 'monero.example:18081', type: WalletType.monero);
    await Future<void>.delayed(Duration.zero);

    verifyNever(() => wallet.connectToNode(node: any(named: 'node')));
  });
}
