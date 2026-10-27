import 'package:cake_wallet/entities/new_main_actions.dart';
import 'package:cake_wallet/src/widgets/cake_image_widget.dart';
import 'package:cake_wallet/view_model/dashboard/dashboard_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';

/// A labelled, keyboard-accessible navigation column for wide Windows windows.
/// The same actions and visibility rules are used by the compact navigation.
class WindowsDashboardNavigation extends StatelessWidget {
  const WindowsDashboardNavigation({
    required this.dashboardViewModel,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  final DashboardViewModel dashboardViewModel;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return SizedBox(
      width: 216,
      child: ColoredBox(
        color: colors.surface,
        child: SafeArea(
          child: Observer(
            builder: (_) {
              final actions = NewMainActions.all
                  .where((action) => action.canShow?.call(dashboardViewModel) ?? true)
                  .toList();

              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CakeImageWidget(
                          imageUrl: theme.brightness == Brightness.dark
                              ? 'assets/images/cake_logo_dark.svg'
                              : 'assets/images/cake_logo_light.svg',
                          width: 38,
                          height: 38,
                        ),
                        const SizedBox(height: 14),
                        Text('Cake Wallet', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(
                          'Windows',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final action in actions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Semantics(
                        selected: NewMainActions.all.indexOf(action) == selectedIndex,
                        child: TextButton(
                          key: action.key,
                          onPressed: (action.isEnabled?.call(dashboardViewModel) ?? true)
                              ? () {
                                  onSelected(NewMainActions.all.indexOf(action));
                                  action.onTap();
                                }
                              : null,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 52),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            foregroundColor: colors.onSurface,
                            backgroundColor: NewMainActions.all.indexOf(action) == selectedIndex
                                ? colors.primary.withAlpha(24)
                                : Colors.transparent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            alignment: Alignment.centerLeft,
                          ),
                          child: Row(
                            children: [
                              ExcludeSemantics(
                                child: CakeImageWidget(
                                  imageUrl: action.image,
                                  width: 23,
                                  height: 23,
                                  colorFilter: ColorFilter.mode(colors.primary, BlendMode.srcIn),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  action.name(context),
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: NewMainActions.all.indexOf(action) == selectedIndex
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
