import 'dart:io';

import 'package:cake_wallet/core/key_service.dart';
import 'package:cake_wallet/core/wallet_loading_service.dart';
import 'package:cake_wallet/entities/preferences_key.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/transaction_history.dart';
import 'package:cw_core/transaction_info.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_service.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Keys extends Mock implements KeyService {}
class _Preferences extends Mock implements SharedPreferences {}
class _Service extends Mock implements WalletService {}
class _Wallet extends Mock
    implements WalletBase<Balance, TransactionHistoryBase<TransactionInfo>, TransactionInfo> {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Windows Monero load failure preserves user control', () {
    late _Keys keys;
    late _Preferences preferences;
    late _Service service;
    late WalletLoadingService loading;
    late int factoryCalls;
    setUp(() {
      keys = _Keys();
      preferences = _Preferences();
      service = _Service();
      factoryCalls = 0;
      loading = WalletLoadingService(preferences, keys, (type) {
        expect(type, WalletType.monero);
        factoryCalls++;
        return service;
      });
    });
    test('open error is preserved without seeds, fallback wallets or selection changes', () async {
      final failure = StateError('Synthetic permission failure');
      when(() => service.openWallet('untouched', 'test-only'))
          .thenAnswer((_) async => throw failure);
      await expectLater(loading.load(WalletType.monero, 'untouched',
          password: 'test-only', isBackground: true), throwsA(same(failure)));
      expect(factoryCalls, 1);
      verify(() => service.openWallet('untouched', 'test-only')).called(1);
      verifyNoMoreInteractions(service);
      verifyZeroInteractions(keys);
      verifyZeroInteractions(preferences);
    });
    test('credential lookup failure cannot trigger seed extraction or other opens', () async {
      final failure = StateError('Synthetic secure-storage failure');
      when(() => keys.getWalletPassword(walletName: 'untouched'))
          .thenAnswer((_) async => throw failure);
      await expectLater(loading.load(WalletType.monero, 'untouched',
          isBackground: true), throwsA(same(failure)));
      expect(factoryCalls, 1);
      verify(() => keys.getWalletPassword(walletName: 'untouched')).called(1);
      verifyNoMoreInteractions(keys);
      verifyZeroInteractions(service);
      verifyZeroInteractions(preferences);
    });
    test('successful loading still returns the requested wallet', () async {
      final wallet = _Wallet();
      when(() => wallet.name).thenReturn('untouched');
      when(() => service.openWallet('untouched', 'test-only')).thenAnswer((_) async => wallet);
      when(() => preferences.getBool(PreferencesKey.moneroWalletUpdateV1Key('untouched')))
          .thenReturn(true);
      expect(await loading.load(WalletType.monero, 'untouched',
          password: 'test-only', isBackground: true), same(wallet));
      expect(factoryCalls, 1);
      verify(() => service.openWallet('untouched', 'test-only')).called(1);
      verifyNoMoreInteractions(service);
      verifyZeroInteractions(keys);
    });
  }, skip: !Platform.isWindows);
}
