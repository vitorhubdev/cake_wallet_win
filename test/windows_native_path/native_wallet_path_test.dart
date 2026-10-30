import 'dart:io';

import '../../cw_monero/lib/api/windows_wallet_path.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  check(Platform.isWindows, 'This native path test must run on Windows.');
  final root = Directory.systemTemp.createTempSync('cake-native-path-');
  try {
    final unicodeDirectory =
        Directory(root.path + r'\wallet data espaço')..createSync();
    final source = unicodeDirectory.path + r'\offline_testnet';
    final short = nativeMoneroWalletPath(source);
    check(short.runes.every((point) => point < 128), 'Non-ASCII native alias.');
    check(short != source, 'Unicode parent was not resolved to an alias.');
    File(source).writeAsStringSync('same-safe-file');
    check(File(short).readAsStringSync() == 'same-safe-file',
        'The native alias must refer to the original file.');
    final ordinary = root.path + r'\wallet_data\offline_testnet';
    check(nativeMoneroWalletPath(ordinary) == ordinary,
        'ASCII paths must remain unchanged.');
    var rejected = false;
    try {
      nativeMoneroWalletPath(unicodeDirectory.path + r'\café');
    } on StateError {
      rejected = true;
    }
    check(rejected, 'Unsupported Unicode wallet filenames must fail closed.');
    stdout.writeln('Windows native wallet path alias checks passed.');
  } finally {
    root.deleteSync(recursive: true);
  }
}
