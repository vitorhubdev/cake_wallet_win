import 'dart:io';

import 'package:cake_wallet/generated/i18n.dart';
import 'package:cake_wallet/core/validator.dart';

class WalletNameValidator extends TextValidator {
  WalletNameValidator({bool? isWindows})
    : _isWindows = isWindows ?? Platform.isWindows,
      super(
        errorMessage: S.current.error_text_wallet_name,
        pattern: '^[a-zA-Z0-9\-_ ]+\$',
        minLength: 1,
        maxLength: 33,
      );

  final bool _isWindows;
  static final _windowsDeviceName = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
    caseSensitive: false,
  );

  @override
  bool isValid(String? value) {
    if (!super.isValid(value)) return false;
    return _isAllowedOnPlatform(value!);
  }

  @override
  String? call(String? value) {
    if (!super.isValid(value)) return errorMessage;
    if (!_isAllowedOnPlatform(value!)) return S.current.error_text_windows_wallet_name;
    return null;
  }

  bool _isAllowedOnPlatform(String value) {
    if (!_isWindows) return true;

    // Wallet names become directory and file names. Windows reserves device
    // names and strips trailing spaces, which can alias a different wallet.
    return !value.endsWith(' ') && !_windowsDeviceName.hasMatch(value);
  }
}
