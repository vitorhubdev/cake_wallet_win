import 'package:cake_wallet/core/sync_status_title.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/routes.dart';
import 'package:cake_wallet/src/widgets/cake_image_widget.dart';
import 'package:cake_wallet/view_model/dashboard/dashboard_view_model.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';

/// Keeps the selected Monero node and real sync state visible on desktop.
/// This widget performs no network requests and never displays node credentials.
class WindowsMoneroConnectionCard extends StatelessWidget {
  const WindowsMoneroConnectionCard({required this.dashboardViewModel, super.key});

  final DashboardViewModel dashboardViewModel;
  static const moneroOrange = Color(0xFFF26822);

  @override
  Widget build(BuildContext context) => Observer(
    builder: (_) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final status = dashboardViewModel.status;
      final node = dashboardViewModel.settingsStore.nodes[WalletType.monero];
      final uri = node?.uri;
      final host = uri?.host ?? '';
      final address = host.isEmpty
          ? S.of(context).sync_not_connected
          : '${host.contains(':') ? '[$host]' : host}:${uri!.port}';
      final title = syncStatusTitle(status, dashboardViewModel.settingsStore.syncStatusDisplayMode);
      final isFailure =
          status is FailedSyncStatus ||
          status is LostConnectionSyncStatus ||
          status is TimedOutSyncStatus ||
          status is UnsupportedSyncStatus;
      final isSynced = status is SyncedSyncStatus;
      final progress = status.progress();

      final information = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExcludeSemantics(
            child: CakeImageWidget(
              imageUrl: 'assets/new-ui/crypto_full_icons/monero.svg',
              width: 40,
              height: 40,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Monero · XMR',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isFailure
                          ? Icons.error_outline
                          : isSynced
                          ? Icons.check_circle_outline
                          : Icons.sync,
                      size: 17,
                      color: isFailure ? colors.error : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title.isEmpty ? S.of(context).synchronizing : title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: isFailure ? colors.error : colors.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
      final manageNodes = OutlinedButton.icon(
        key: const ValueKey('windows_monero_manage_nodes_button'),
        onPressed: () => Navigator.of(context).pushNamed(Routes.manageNodes),
        icon: const Icon(Icons.settings_ethernet, size: 20),
        label: Text(S.of(context).manage_nodes),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 46),
          foregroundColor: colors.onSurface,
          side: BorderSide(color: colors.outline.withAlpha(120)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );

      return Container(
        key: const ValueKey('windows_monero_connection_card'),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 560) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [information, const SizedBox(height: 16), manageNodes],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: information),
                    const SizedBox(width: 24),
                    manageNodes,
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Tooltip(
              message: address,
              child: Text(
                '${S.of(context).node_address}: $address',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFamily: 'Consolas',
                ),
              ),
            ),
            if (status is SyncingSyncStatus && progress.isFinite) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0).toDouble(),
                  minHeight: 4,
                  color: moneroOrange,
                  backgroundColor: colors.surfaceContainerHighest,
                  semanticsLabel: S.of(context).synchronizing,
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
