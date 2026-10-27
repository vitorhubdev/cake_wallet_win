import 'dart:convert';
import 'dart:io';

import 'generate_new_secrets.dart' show generateSecrets;
import 'generate_secrets_config.dart' as config;
import 'utils/secret_key.dart';

/// Public compatibility constants for vitorhubdev/cake_wallet_win, profile v1.
///
/// These are not wallet seeds, API credentials, or the keys that encrypt wallet
/// files. The upstream app embeds these constants in every binary and uses them
/// to encode values kept in the operating system's secure storage. That secure
/// storage must remain enabled. Never use --excludeFlutterSecureStorage.
///
/// Do not change these values between builds: doing so would invalidate stored
/// PINs, wallet passwords, backups, and wallet-group identifiers. This profile is
/// deliberately separate from official Cake builds; their encrypted app data and
/// backups are not assumed to be compatible. Recovery phrases remain independent
/// of this build configuration.
///
/// Values are the indicated-length prefixes of SHA-256 of
/// `vitorhubdev/cake_wallet_win:windows-profile-v1:<field name>`.
const windowsCompatibilityValues = <String, String>{
  'salt': '30b40ff990413a54e160d1d9029e0325',
  'keychainSalt': '1310d2ac8e46cdfa2189725f',
  'key': '75be593c84a795178bfb86a47c0fd79e',
  'walletSalt': '00c7d74e',
  'shortKey': '08e9ed48cf21871de2391256',
  'backupSalt': 'b834322dd168c5e3',
  'backupKeychainSalt': '8ba15c76b1f46bd77556bba2',
  'walletGroupSalt': 'e63f7353f8a1f6b9f214ce1587ad564e',
};

Future<void> main() => configureWindowsSecrets();

/// Generates the public Windows profile using the upstream configuration schema.
/// Run from the repository root. Never prints configuration values.
Future<void> configureWindowsSecrets() async {
  final auxiliaryConfigs = <String, List<SecretKey>>{
    config.evmChainsConfigPath: SecretKey.evmChainsSecrets,
    config.solanaConfigPath: SecretKey.solanaSecrets,
    config.nanoConfigPath: SecretKey.nanoSecrets,
    config.tronConfigPath: SecretKey.tronSecrets,
    config.bitcoinConfigPath: SecretKey.bitcoinSecrets,
  };

  // Validate all existing files before writing anything. An accidental local
  // configuration must not silently replace this profile or leak credentials
  // into an artifact intended to contain only public build configuration.
  for (final path in [config.baseConfigPath, ...auxiliaryConfigs.keys]) {
    final file = File(path);
    if (!file.existsSync()) continue;

    Map<String, dynamic> values;
    try {
      values = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      throw StateError('Invalid build configuration in $path. Use a clean checkout.');
    }

    if (path == config.baseConfigPath) {
      for (final entry in windowsCompatibilityValues.entries) {
        if (values[entry.key] != entry.value) {
          throw StateError(
              'Incompatible Windows build configuration in $path. Use a clean checkout.');
        }
      }
    }
    for (final entry in values.entries) {
      if (path == config.baseConfigPath && windowsCompatibilityValues.containsKey(entry.key)) {
        continue;
      }
      if (entry.value != '') {
        throw StateError('Non-public build configuration in $path. Use a clean checkout.');
      }
    }
  }

  // Repair an interrupted generation with a valid base profile. The upstream
  // generator returns early when its base JSON already exists.
  if (File(config.baseConfigPath).existsSync()) {
    for (final entry in auxiliaryConfigs.entries) {
      final file = File(entry.key);
      if (!file.existsSync()) await config.writeConfig(file, entry.value);
    }
  }

  await generateSecrets([
    for (final entry in windowsCompatibilityValues.entries) '${entry.key}=${entry.value}',
  ]);
}
