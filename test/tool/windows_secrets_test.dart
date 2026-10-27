import 'dart:convert';
import 'dart:io';

import 'package:cake_wallet/entities/encrypt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/configure_windows_secrets.dart';

void main() {
  late Directory originalDirectory;
  late Directory temporaryDirectory;

  setUp(() async {
    originalDirectory = Directory.current;
    temporaryDirectory = await Directory.systemTemp.createTemp('cake-windows-profile-');
    Directory.current = temporaryDirectory;
    for (final path in [
      'tool',
      'lib',
      'cw_evm/lib',
      'cw_solana/lib',
      'cw_nano/lib',
      'cw_tron/lib',
      'cw_bitcoin/lib',
    ]) {
      await Directory(path).create(recursive: true);
    }
  });

  tearDown(() async {
    Directory.current = originalDirectory;
    await temporaryDirectory.delete(recursive: true);
  });

  Future<Map<String, String>> generatedFiles() async {
    final files = <String, String>{};
    await for (final entry in temporaryDirectory.list(recursive: true)) {
      if (entry is File) {
        files[entry.path.substring(temporaryDirectory.path.length)] = await entry.readAsString();
      }
    }
    return files;
  }

  test('separate clean builds and repeated generation keep identical configuration', () async {
    await configureWindowsSecrets();
    final firstBuild = await generatedFiles();
    expect(firstBuild.length, 12); // Six JSON inputs and six generated Dart files.

    await configureWindowsSecrets();
    expect(await generatedFiles(), firstBuild);

    final generated = await temporaryDirectory.list(recursive: true).where((e) => e is File).toList();
    for (final file in generated) {
      await file.delete();
    }
    await configureWindowsSecrets();
    expect(await generatedFiles(), firstBuild);
  });

  test('compatibility values preserve required lengths and all credentials stay empty', () async {
    await configureWindowsSecrets();
    const expectedLengths = {
      'salt': 32,
      'keychainSalt': 24,
      'key': 32,
      'walletSalt': 8,
      'shortKey': 24,
      'backupSalt': 16,
      'backupKeychainSalt': 24,
      'walletGroupSalt': 32,
    };
    final base = jsonDecode(await File('tool/.secrets-config.json').readAsString())
        as Map<String, dynamic>;
    for (final entry in expectedLengths.entries) {
      expect(base[entry.key], matches(RegExp('^[0-9a-f]{${entry.value}}\$')));
    }
    for (final entry in base.entries) {
      if (!expectedLengths.containsKey(entry.key)) expect(entry.value, isEmpty, reason: entry.key);
    }
    final generated = await generatedFiles();
    for (final entry in generated.entries) {
      if (!entry.key.endsWith('.json') || entry.key.endsWith('/.secrets-config.json') ||
          entry.key.endsWith('\\.secrets-config.json')) continue;
      final values = jsonDecode(entry.value) as Map<String, dynamic>;
      expect(values.values, everyElement(isEmpty));
    }
  });

  test('refuses incompatible existing configuration without overwriting files', () async {
    await configureWindowsSecrets();
    final configFile = File('tool/.secrets-config.json');
    final values = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    values['salt'] = 'incompatible-build-profile';
    await configFile.writeAsString(jsonEncode(values));
    final before = await generatedFiles();

    await expectLater(configureWindowsSecrets(), throwsStateError);
    expect(await generatedFiles(), before);
  });

  test('refuses nonempty integration credentials without overwriting files', () async {
    await configureWindowsSecrets();
    final configFile = File('tool/.bitcoin-secrets-config.json');
    await configFile.writeAsString(jsonEncode({'breezApiKey': 'dummy-test-value'}));
    final before = await generatedFiles();

    await expectLater(configureWindowsSecrets(), throwsStateError);
    expect(await generatedFiles(), before);
  });

  test('repairs interrupted generation while preserving the compatibility profile', () async {
    await configureWindowsSecrets();
    final before = await generatedFiles();
    await File('tool/.bitcoin-secrets-config.json').delete();
    await File('cw_bitcoin/lib/.secrets.g.dart').delete();

    await configureWindowsSecrets();
    expect(await generatedFiles(), before);
  });

  test('v1 persisted PIN and wallet-password fixtures remain readable after updates', () {
    // Synthetic fixtures from the initial public Windows profile; no real wallet
    // or credentials. Keeping these ciphertexts fixed detects compatibility breaks.
    const storedPin = 'ZyHUIiIcgmzoCCZdMynWkmOh3GGO4ZmTh21qJbz1FLVnSftyKUVpR/0edS57HzXS';
    const storedWalletPassword = 'jW3PlfnO9NSwM4ePCTUDMEcM7Sv+oj5dpkctfPhz/7k=';

    expect(decodedPinCode(pin: storedPin), '123456');
    expect(encodedPinCode(pin: '123456'), storedPin);
    expect(decodeWalletPassword(password: storedWalletPassword), 'windows-test-wallet-password');
    expect(encodeWalletPassword(password: 'windows-test-wallet-password'), storedWalletPassword);
  });
}
