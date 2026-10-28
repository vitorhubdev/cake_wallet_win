import 'dart:io';

import 'package:cake_wallet/core/wallet_name_validator.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() {
    S.current = S();
  });

  test('Windows rejects reserved device names in any letter case', () {
    final validator = WalletNameValidator(isWindows: true);
    final reserved = [
      'CON',
      'PRN',
      'AUX',
      'NUL',
      for (var number = 1; number <= 9; number++) 'COM$number',
      for (var number = 1; number <= 9; number++) 'LPT$number',
    ];

    for (final name in reserved) {
      expect(validator.isValid(name), isFalse, reason: name);
      expect(validator.isValid(name.toLowerCase()), isFalse, reason: name.toLowerCase());
      expect(validator(name), S.current.error_text_windows_wallet_name, reason: name);
    }
    expect(validator.isValid('cOn'), isFalse);
    expect(validator.isValid('LpT9'), isFalse);
  });

  test('Windows rejects trailing spaces rather than aliasing another wallet', () {
    final validator = WalletNameValidator(isWindows: true);
    for (final name in ['XMR ', 'XMR  ', ' ', '   ', 'CON ']) {
      expect(validator.isValid(name), isFalse, reason: '"$name"');
    }
    expect(validator('XMR '), S.current.error_text_windows_wallet_name);
  });

  test('Windows retains ordinary names and nonreserved device-name boundaries', () {
    final validator = WalletNameValidator(isWindows: true);
    for (final name in [
      'XMR',
      'Main wallet',
      'xmr-2026',
      '_wallet',
      ' wallet',
      'COM0',
      'COM10',
      'LPT0',
      'LPT10',
      'CONwallet',
      'My AUX',
      'a' * 33,
    ]) {
      expect(validator.isValid(name), isTrue, reason: name);
      expect(validator(name), isNull, reason: name);
    }
  });

  test('Windows rules do not bypass existing character and length validation', () {
    for (final isWindows in [true, false]) {
      final validator = WalletNameValidator(isWindows: isWindows);
      for (final name in <String?>[
        null,
        '',
        'a' * 34,
        'wallet/name',
        r'wallet\name',
        'name.',
        'name:other',
        'name\n',
        'COM¹',
      ]) {
        expect(validator.isValid(name), isFalse, reason: '$isWindows: $name');
        expect(validator(name), S.current.error_text_wallet_name, reason: '$isWindows: $name');
      }
    }
  });

  test('other platforms preserve their existing wallet-name behavior', () {
    final validator = WalletNameValidator(isWindows: false);
    for (final name in ['CON', 'nul', 'AUX', 'COM1', 'LPT9', 'XMR ', ' ']) {
      expect(validator.isValid(name), isTrue, reason: '"$name"');
      expect(validator(name), isNull, reason: '"$name"');
    }
  });

  test('the default validator uses the actual platform', () {
    final validator = WalletNameValidator();
    expect(validator.isValid('CON'), !Platform.isWindows);
    expect(validator.isValid('XMR '), !Platform.isWindows);
    expect(validator.isValid('Main XMR'), isTrue);
  });
}
