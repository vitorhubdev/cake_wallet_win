import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/routes.dart';
import 'package:cake_wallet/src/widgets/cake_image_widget.dart';
import 'package:cake_wallet/src/widgets/primary_button.dart';
import 'package:flutter/material.dart';

/// Static desktop onboarding: readable at wide sizes and scrollable in a small
/// window. It shares the existing wallet setup route and PIN button contract.
class WindowsWelcomePanel extends StatelessWidget {
  const WindowsWelcomePanel({required this.isWalletPasswordDirectInput, super.key});

  final bool isWalletPasswordDirectInput;
  static const moneroOrange = Color(0xFFF26822);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final strings = S.of(context);

    return PopScope(
      canPop: false,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: viewport.maxHeight),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 980),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 800;
                          final introduction = Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  ExcludeSemantics(
                                    child: CakeImageWidget(
                                      imageUrl: theme.brightness == Brightness.dark
                                          ? 'assets/images/cake_logo_dark.svg'
                                          : 'assets/images/cake_logo_light.svg',
                                      width: 32,
                                      height: 32,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Cake Wallet Windows',
                                      style: theme.textTheme.titleMedium,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 40),
                              Text(
                                strings.welcome,
                                style: theme.textTheme.displayMedium?.copyWith(
                                  fontSize: wide ? 48 : 38,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -1.2,
                                ),
                              ),
                              const SizedBox(height: 24),
                              Row(
                                children: [
                                  const ExcludeSemantics(
                                    child: CakeImageWidget(
                                      imageUrl: 'assets/new-ui/crypto_full_icons/monero.svg',
                                      width: 48,
                                      height: 48,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Text(
                                      'Monero · XMR',
                                      style: theme.textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Text(
                                strings.windows_welcome_description,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  height: 1.6,
                                  color: colors.onSurface,
                                ),
                              ),
                            ],
                          );
                          final setup = Container(
                            padding: const EdgeInsets.all(28),
                            decoration: BoxDecoration(
                              color: colors.surfaceContainer,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: colors.outlineVariant),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: moneroOrange.withAlpha(24),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(Icons.lock_outline, color: colors.onSurface),
                                ),
                                const SizedBox(height: 22),
                                Text(
                                  strings.privacy_and_security,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  strings.windows_welcome_setup,
                                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                                ),
                                const SizedBox(height: 28),
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      strings.windows_terms_intro,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pushNamed(context, Routes.readDisclaimer),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 0),
                                        minimumSize: const Size(48, 36),
                                        alignment: Alignment.centerLeft,
                                      ),
                                      child: Text(
                                        strings.windows_terms_link,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: colors.onSurface,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                PrimaryButton(
                                  key: const ValueKey(
                                    'create_pin_welcome_page_create_a_pin_button_key',
                                  ),
                                  onPressed: () =>
                                      Navigator.pushNamed(context, Routes.welcomeWallet),
                                  text: isWalletPasswordDirectInput
                                      ? strings.set_up_a_wallet
                                      : strings.set_a_pin,
                                  color: colors.primaryContainer,
                                  textColor: colors.onPrimaryContainer,
                                ),
                              ],
                            ),
                          );

                          if (!wide) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [introduction, const SizedBox(height: 32), setup],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(flex: 6, child: introduction),
                              const SizedBox(width: 56),
                              Expanded(flex: 5, child: setup),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
