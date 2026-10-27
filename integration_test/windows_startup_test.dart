import 'dart:async';
import 'dart:io';

import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/main.dart' as app;
import 'package:cake_wallet/src/screens/welcome/create_pin_welcome_page.dart';
import 'package:cake_wallet/src/widgets/primary_button.dart';
import 'package:cw_core/db/sqlite.dart' as wallet_db;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

// This target uses the real application, assets, plugins, database, and secure
// storage. It does not create a wallet or use a seed, node, or payment fixture.
// Run it only on a disposable GitHub-hosted Windows runner with a new, empty
// CAKE_WALLET_DIR. Other platform suites have their own launchers/fixtures.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows starts the real application and displays the enabled onboarding button',
    (tester) async {
      expect(Platform.environment['GITHUB_ACTIONS'], 'true');
      expect(Platform.environment['RUNNER_ENVIRONMENT'], 'github-hosted');
      final profilePath = Platform.environment['CAKE_WALLET_DIR'];
      expect(profilePath, isNotNull, reason: 'A disposable wallet directory is required.');
      expect(profilePath, isNotEmpty);
      final profile = Directory(profilePath!);
      if (profile.existsSync()) {
        expect(profile.listSync(), isEmpty, reason: 'Never test against an existing wallet.');
      } else {
        profile.createSync(recursive: true);
      }

      final frameworkErrorHandler = FlutterError.onError;
      final platformErrorHandler = WidgetsBinding.instance.platformDispatcher.onError;
      addTearDown(() {
        FlutterError.onError = frameworkErrorHandler;
        WidgetsBinding.instance.platformDispatcher.onError = platformErrorHandler;
      });
      Object? launchError;
      // Startup errors can be caught by the app and rendered as a perfectly
      // live TopLevelErrorWidget. Poll the actual widget tree rather than
      // treating a running process or first frame as success.
      unawaited(app.main().then((_) {
        FlutterError.onError = frameworkErrorHandler;
      }, onError: (Object error, StackTrace stack) {
        launchError = error;
        FlutterError.onError = frameworkErrorHandler;
      }));

      final deadline = DateTime.now().add(const Duration(seconds: 75));
      final onboarding = find.byType(CreatePinWelcomePage);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
        if (launchError != null) {
          fail('Application startup failed: $launchError');
        }
        final errorPage = find.byType(app.TopLevelErrorWidget);
        if (tester.any(errorPage)) {
          final error = tester.widget<app.TopLevelErrorWidget>(errorPage);
          fail('Application rendered a startup error: ${error.error}\n${error.stackTrace}');
        }
        expect(find.byType(ErrorWidget), findsNothing);
        if (tester.any(onboarding)) break;
      }

      expect(onboarding, findsOneWidget, reason: 'The real onboarding page must be visible.');
      final buttonFinder = find.byKey(
        const ValueKey('create_pin_welcome_page_create_a_pin_button_key'),
      );
      expect(buttonFinder, findsOneWidget);
      final button = tester.widget<PrimaryButton>(buttonFinder);
      expect(button.onPressed, isNotNull);
      expect(button.isDisabled, isFalse);
      expect(find.text(S.current.welcome), findsOneWidget);
      expect(find.text(button.text), findsOneWidget);
      expect(find.byType(app.TopLevelErrorWidget), findsNothing);
      // Regression: initDb used to run before CAKE_WALLET_DIR was applied,
      // splitting the database and wallet files across two different roots.
      expect(wallet_db.db, isNotNull);
      final expectedDbPath = p.join(profile.path, 'cake.db');
      expect(p.equals(wallet_db.db!.path, expectedDbPath), isTrue);
      expect(File(expectedDbPath).existsSync(), isTrue);
      expect(wallet_db.db!.isOpen, isTrue);
      expect(tester.takeException(), isNull);
      // We deliberately stop before agreeing to terms or creating a wallet.
      // Transaction/synchronization behavior is not covered by this test.
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
