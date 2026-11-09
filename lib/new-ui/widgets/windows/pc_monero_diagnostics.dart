import 'dart:async';

import 'package:cw_core/monero_node_health.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cake_wallet/utils/monero_health_text.dart';
import 'package:flutter/material.dart';

/// User-triggered metadata probe. No balance, address, seed or external-IP lookup.
class PcMoneroDiagnostics extends StatefulWidget {
  const PcMoneroDiagnostics({
    required this.node,
    required this.status,
    required this.walletIdentity,
    this.testnet = false,
    super.key,
  });
  final Node? node;
  final SyncStatus status;
  final Object walletIdentity;
  final bool testnet;
  @override
  State<PcMoneroDiagnostics> createState() => _PcMoneroDiagnosticsState();
}

class _PcMoneroDiagnosticsState extends State<PcMoneroDiagnostics> {
  MoneroNodeHealth? _health;
  MoneroProbeCancellation? _cancellation;
  String? _identity;
  bool _testing = false;
  Timer? _cooldownTimer;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _identity = widget.node?.healthIdentity;
  }

  @override
  void didUpdateWidget(PcMoneroDiagnostics oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identity = widget.node?.healthIdentity;
    if (identity != _identity || !identical(widget.walletIdentity, oldWidget.walletIdentity)) {
      _generation++;
      _cancellation?.cancel();
      _cooldownTimer?.cancel();
      _identity = identity;
      _health = null;
      _testing = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _cancellation?.cancel();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  int get _cooldownSeconds {
    final value = _health;
    if (value == null || value.retryAfter == null) return 0;
    final remaining = value.checkedAt.add(value.retryAfter!).difference(DateTime.now()).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  Future<void> _test() async {
    final current = widget.node;
    if (current == null || _testing || _cooldownSeconds > 0) return;
    final generation = ++_generation;
    final identity = current.healthIdentity;
    final cancellation = MoneroProbeCancellation();
    _cancellation = cancellation;
    setState(() {
      _testing = true;
      _health = null;
    });
    final result = await current.probeMoneroHealth(
      expectedNetwork: widget.testnet ? 'testnet' : 'mainnet',
      cancellation: cancellation,
    );
    if (!mounted || generation != _generation) return;
    if (widget.node?.healthIdentity != identity) {
      setState(() {
        _health = null;
        _testing = false;
        _identity = widget.node?.healthIdentity;
      });
      return;
    }
    setState(() {
      _health = result;
      _testing = false;
    });
    if (_cooldownSeconds > 0) {
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || generation != _generation) {
          timer.cancel();
          return;
        }
        setState(() {});
        if (_cooldownSeconds == 0) timer.cancel();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pt = Localizations.localeOf(context).languageCode == 'pt';
    final theme = Theme.of(context);
    final status = widget.status;
    final health = _health;
    final rate = status is MoneroSyncingSyncStatus ? status.metrics : null;
    final rateText = rate?.blocksPerSecond == null
        ? (pt ? 'Calculando avanço…' : 'Measuring scan progress…')
        : '${rate!.blocksPerSecond!.toStringAsFixed(1)} ${pt ? 'blocos/s' : 'blocks/s'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status is MoneroSyncingSyncStatus) ...[
          const SizedBox(height: 10),
          Text(
            '$rateText · ${status.blocksLeft} ${pt ? 'blocos restantes' : 'blocks remaining'}',
            key: const ValueKey('pc_xmr_scan_speed'),
            style: theme.textTheme.bodySmall,
          ),
          if (rate?.stalled == true)
            Text(
              pt
                  ? 'Sem avanço observado há ${rate!.withoutProgress.inSeconds}s. O scan pode estar processando dados; teste o nó antes de trocar.'
                  : 'No observed progress for ${rate!.withoutProgress.inSeconds}s. The scan may be processing data; test the node before switching.',
              style: theme.textTheme.bodySmall,
            ),
        ],
        const SizedBox(height: 8),
        TextButton.icon(
          key: const ValueKey('pc_xmr_probe_button'),
          onPressed: widget.node == null || _testing || _cooldownSeconds > 0 ? null : _test,
          icon: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_ping, size: 18),
          label: Text(
            _testing
                ? (pt ? 'Medindo latência RPC…' : 'Measuring RPC latency…')
                : _cooldownSeconds > 0
                ? '${pt ? 'Aguarde' : 'Wait'} ${_cooldownSeconds}s'
                : (pt ? 'Testar nó e latência (ms)' : 'Test node and latency (ms)'),
          ),
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
        ),
        if (health != null) ...[
          Text(
            moneroHealthTitle(health, portuguese: pt),
            key: const ValueKey('pc_xmr_probe_result'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: health.rpcAvailable ? theme.colorScheme.onSurface : theme.colorScheme.error,
            ),
          ),
          Text(moneroHealthDetail(health, portuguese: pt), style: theme.textTheme.bodySmall),
          Text(
            pt
                ? 'Latência RPC inclui DNS, conexão e resposta. Blocos/s mede o scan da carteira, não Mbps. Responder rápido não comprova que o nó seja confiável.'
                : 'RPC latency includes DNS, connection and response. Blocks/s measures wallet scanning, not Mbps. A fast reply is not proof of node trust.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
