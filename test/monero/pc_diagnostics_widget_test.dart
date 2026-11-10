import 'dart:async';

import 'package:cake_wallet/new-ui/widgets/windows/pc_monero_diagnostics.dart';
import 'package:cw_core/monero_node_health.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/utils/monero_sync_metrics.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ProbeNode extends Node {
  ProbeNode(this.reply) : super(uri: 'localhost:18081', type: WalletType.monero);
  final Future<MoneroNodeHealth> Function() reply;
  int calls = 0;
  @override
  Future<MoneroNodeHealth> probeMoneroHealth({
    String expectedNetwork = 'mainnet',
    int samples = 3,
    Duration timeout = const Duration(seconds: 15),
    MoneroProbeCancellation? cancellation,
  }) {
    calls++;
    return reply();
  }
}

void main() {
  final identity = Object();
  Widget view(Node node, {SyncStatus? status, Object? wallet}) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: PcMoneroDiagnostics(
          node: node,
          status: status ?? SyncedSyncStatus(),
          walletIdentity: wallet ?? identity,
        ),
      ),
    ),
  );

  testWidgets('explicit probe displays real milliseconds without duplicate clicks', (tester) async {
    final response = Completer<MoneroNodeHealth>();
    final node = ProbeNode(() => response.future);
    await tester.pumpWidget(view(node));
    expect(node.calls, 0);
    await tester.tap(find.byKey(const ValueKey('pc_xmr_probe_button')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pc_xmr_probe_button')));
    expect(node.calls, 1);
    response.complete(
      MoneroNodeHealth(
        state: MoneroNodeState.ready,
        checkedAt: DateTime.now(),
        latencyMs: 37,
        jitterMs: 5,
        samples: 3,
        height: 100,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('37 ms'), findsOneWidget);
    expect(find.textContaining('Mbps'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rate and failure text fit a narrow desktop panel', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = ProbeNode(
      () => Future.value(
        MoneroNodeHealth(
          state: MoneroNodeState.forbidden,
          checkedAt: DateTime.now(),
          httpStatus: 403,
        ),
      ),
    );
    await tester.pumpWidget(
      view(
        node,
        status: MoneroSyncingSyncStatus(
          1000,
          .5,
          scannedHeight: 12000,
          metrics: const MoneroSyncMetrics(blocksPerSecond: 12.5, samples: 4),
        ),
      ),
    );
    expect(find.textContaining('12.5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pc_xmr_probe_button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not confirm an IP ban'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late result from a replaced wallet is discarded', (tester) async {
    final response = Completer<MoneroNodeHealth>();
    final node = ProbeNode(() => response.future);
    await tester.pumpWidget(view(node));
    await tester.tap(find.byKey(const ValueKey('pc_xmr_probe_button')));
    await tester.pump();
    await tester.pumpWidget(view(node, wallet: Object()));
    response.complete(
      MoneroNodeHealth(state: MoneroNodeState.ready, checkedAt: DateTime.now(), latencyMs: 999),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('999 ms'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
