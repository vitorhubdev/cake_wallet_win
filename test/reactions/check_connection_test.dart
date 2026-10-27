import 'dart:async';

import 'package:cake_wallet/reactions/check_connection.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSettingsStore extends Mock implements SettingsStore {}

class _MockWallet extends Mock
    implements WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {}

class _ProbeNode extends Node {
  _ProbeNode(this.probe, {String host = 'monero.example:18081'})
    : super(uri: host, type: WalletType.monero);

  final Future<bool> Function() probe;
  int probes = 0;

  @override
  Future<bool> requestNode() {
    probes++;
    return probe();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const connectivityChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  late _MockWallet wallet;
  late _MockSettingsStore settings;
  late SyncStatus status;
  late _ProbeNode node;
  late Node selectedNode;
  late Completer<bool> probeResult;
  late bool currentWallet;
  late List<String> connectivity;

  void start() {
    startCheckConnectionReaction(
      wallet,
      settings,
      timeInterval: 1,
      isCurrentWallet: () => currentWallet,
    );
  }

  setUpAll(() {
    registerFallbackValue(Node(uri: 'unused.example:18081', type: WalletType.monero));
    registerFallbackValue(FailedSyncStatus());
  });

  setUp(() {
    wallet = _MockWallet();
    settings = _MockSettingsStore();
    status = FailedSyncStatus();
    currentWallet = true;
    connectivity = ['wifi'];
    probeResult = Completer<bool>();
    node = _ProbeNode(() => probeResult.future);
    selectedNode = node;

    when(() => wallet.type).thenReturn(WalletType.monero);
    when(() => wallet.syncStatus).thenAnswer((_) => status);
    when(() => wallet.syncStatus = any()).thenAnswer((invocation) {
      status = invocation.positionalArguments.single as SyncStatus;
    });
    when(() => wallet.connectToNode(node: any(named: 'node'))).thenAnswer((_) async {
      status = ConnectedSyncStatus();
    });
    when(() => settings.currentBuiltinTor).thenReturn(false);
    when(
      () => settings.getCurrentNode(WalletType.monero, chainId: null),
    ).thenAnswer((_) => selectedNode);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      connectivityChannel,
      (_) async => connectivity,
    );
  });

  tearDown(() {
    stopCheckConnectionReaction();
    if (!probeResult.isCompleted) probeResult.complete(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      connectivityChannel,
      null,
    );
  });

  testWidgets('a slow Monero probe does not overlap every timer tick', (tester) async {
    start();
    await tester.pump(const Duration(seconds: 1));
    expect(node.probes, 1);

    await tester.pump(const Duration(seconds: 8));
    expect(node.probes, 1);
    verifyNever(() => wallet.connectToNode(node: any(named: 'node')));

    probeResult.complete(false);
    await tester.pump();
    stopCheckConnectionReaction();
  });

  testWidgets('an unresponsive node releases the check after ten seconds', (tester) async {
    start();
    await tester.pump(const Duration(seconds: 1));
    expect(node.probes, 1);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));

    expect(node.probes, 2);
    verifyNever(() => wallet.connectToNode(node: any(named: 'node')));
    stopCheckConnectionReaction();
    probeResult.complete(false);
    await tester.pump();
  });

  testWidgets('a completed probe cannot reconnect a wallet that was closed', (tester) async {
    start();
    await tester.pump(const Duration(seconds: 1));
    currentWallet = false;
    probeResult.complete(true);
    await tester.pump();

    verifyNever(() => wallet.connectToNode(node: any(named: 'node')));
    stopCheckConnectionReaction();
  });

  testWidgets('a manual node choice wins over an older pending probe', (tester) async {
    start();
    await tester.pump(const Duration(seconds: 1));
    selectedNode = Node(uri: 'chosen.example:18081', type: WalletType.monero);
    probeResult.complete(true);
    await tester.pump();

    verifyNever(() => wallet.connectToNode(node: any(named: 'node')));
    stopCheckConnectionReaction();
  });

  testWidgets('a wallet already reconnected is not initialized again', (tester) async {
    start();
    await tester.pump(const Duration(seconds: 1));
    status = ConnectedSyncStatus();
    probeResult.complete(true);
    await tester.pump();

    verifyNever(() => wallet.connectToNode(node: any(named: 'node')));
    stopCheckConnectionReaction();
  });

  testWidgets('a reachable LAN node reconnects once when Windows reports offline', (tester) async {
    connectivity = ['none'];
    start();
    await tester.pump(const Duration(seconds: 1));
    probeResult.complete(true);
    await tester.pump();

    expect(node.probes, 1);
    verify(() => wallet.connectToNode(node: node)).called(1);
    stopCheckConnectionReaction();
  });

  testWidgets('stopping a check invalidates its pending connection result', (tester) async {
    start();
    await tester.pump(const Duration(seconds: 1));
    stopCheckConnectionReaction();
    probeResult.complete(true);
    await tester.pump();

    verifyNever(() => wallet.connectToNode(node: any(named: 'node')));
  });
}
