// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:monero/monero.dart' as monero;
import 'package:path/path.dart' as p;

// Exercise the packaged native library with an unfunded, randomly generated
// TESTNET wallet. No daemon is initialized and no network operation is invoked.
// Wallet material stays in memory/a private temporary directory, is never
// logged, and is deleted when the worker exits. These are real native operations,
// not mocked responses. This does not cover mainnet sync or sending funds.
const _resultPrefix = 'CAKE_MONERO_SMOKE ';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('This test requires the packaged Windows x64 library.');
  }
  if (args.length == 3 && args.first == '--worker') {
    _worker(args[1], args[2]);
    return;
  }
  if (args.length != 1) {
    throw ArgumentError('Usage: dart run tool/windows_monero_smoke.dart <bundle path>');
  }

  final bundle = Directory(args.single).absolute;
  final library = File(p.join(bundle.path, 'libmonero_wallet2_api_c.dll'));
  if (!library.existsSync()) throw StateError('The packaged Monero DLL is missing.');
  final temporary = await Directory.systemTemp.createTemp('cake-monero-smoke-');
  Process? worker;
  try {
    final packageConfig = await Isolate.packageConfig;
    worker = await Process.start(
      Platform.resolvedExecutable,
      [
        if (packageConfig != null) '--packages=${packageConfig.toFilePath()}',
        Platform.script.toFilePath(),
        '--worker',
        bundle.path,
        temporary.path,
      ],
      // Windows' dependent-DLL resolution must see the distributed DLLs.
      // smoke_test.ps1 separately verifies them without relying on build PATH.
      workingDirectory: bundle.path,
      environment: {'PATH': '${bundle.path};${Platform.environment['PATH'] ?? ''}'},
    );
    final output = worker.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .where((line) => line.startsWith(_resultPrefix))
        .toList();
    // Drain but do not publish arbitrary native diagnostic output: private
    // wallet material must never find its way into CI logs or artifacts.
    final errors = worker.stderr.drain<void>();
    final code = await worker.exitCode.timeout(const Duration(seconds: 90));
    await errors;
    final resultLines = await output;
    if (resultLines.length != 1) {
      throw StateError('Native Monero test exited with code $code without a valid result.');
    }
    final result = jsonDecode(resultLines.single.substring(_resultPrefix.length))
        as Map<String, dynamic>;
    if (code != 0 || result['ok'] != true) {
      throw StateError('Native Monero test failed during ${result['step']} (exit $code).');
    }
    stdout.writeln(jsonEncode(result));
  } on TimeoutException {
    throw StateError('Native Monero test exceeded the 90-second process deadline.');
  } finally {
    if (worker != null) {
      // Killing an already-exited process is harmless; only this owned process
      // is targeted. A separate process is necessary because synchronous FFI
      // cannot be interrupted by a timeout on the same Dart isolate.
      worker.kill();
      await worker.exitCode.timeout(const Duration(seconds: 5));
    }
    await temporary.delete(recursive: true);
  }
}

void _worker(String bundlePath, String temporaryPath) {
  String step = 'load and ABI validation';
  Pointer<Void>? manager;
  Pointer<Void>? activeWallet;
  void require(bool condition, String operation) {
    if (!condition) throw StateError(operation);
  }

  void checkWallet() {
    require(activeWallet != null && activeWallet!.address != 0, 'Native wallet is null.');
    require(monero.Wallet_status(activeWallet!) == 0, 'Native wallet status is not OK.');
    monero.Wallet_setOffline(activeWallet!, offline: true);
    require(monero.Wallet_isOffline(activeWallet!), 'Native wallet is not offline.');
  }

  void closeWallet() {
    final pointer = activeWallet!;
    // Do not retry a native close: ownership may have been consumed even when
    // its result is false. The worker process bounds the remaining lifetime.
    activeWallet = null;
    require(monero.WalletManager_closeWallet(manager!, pointer, false), 'Native close failed.');
  }

  try {
    monero.libPath = p.join(bundlePath, 'libmonero_wallet2_api_c.dll');
    monero.printStarts = false;
    monero.debugStart = null;
    monero.debugEnd = null;
    monero.errorHandler = (call, error) => throw StateError('Native wrapper conversion failed.');
    require(
      monero.MONERO_checksum_wallet2_api_c_h() == monero.wallet2_api_c_h_sha256,
      'The native header does not match the pinned Dart wrapper.',
    );
    require(
      monero.MONERO_checksum_wallet2_api_c_cpp() == monero.wallet2_api_c_cpp_sha256,
      'The native implementation does not match the pinned Dart wrapper.',
    );
    monero.WalletManagerFactory_setLogLevel(-1);
    manager = monero.WalletManagerFactory_getWalletManager();
    require(manager!.address != 0, 'Native wallet manager is null.');

    const networkType = 1; // Monero TESTNET, not mainnet.
    final random = Random.secure();
    final password = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
    final walletDirectory = Directory(p.join(temporaryPath, 'wallet data'))..createSync();
    final walletPath = p.join(walletDirectory.path, 'offline_testnet');

    step = 'create testnet wallet';
    activeWallet = monero.WalletManager_createWallet(
      manager!,
      path: walletPath,
      password: password,
      language: 'English',
      networkType: networkType,
    );
    checkWallet();
    final address = monero.Wallet_address(activeWallet!);
    require(monero.Wallet_addressValid(address, networkType), 'Invalid generated testnet address.');
    final seed = monero.Wallet_seed(activeWallet!, seedOffset: '');
    require(seed.trim().split(RegExp(r'\s+')).length == 25, 'Invalid generated legacy seed.');

    step = 'store and close';
    require(monero.Wallet_store(activeWallet!), 'Native wallet storage failed.');
    closeWallet();
    require(File(walletPath).existsSync(), 'Wallet cache file was not stored.');
    require(File('$walletPath.keys').existsSync(), 'Wallet key file was not stored.');

    step = 'reject incorrect password';
    activeWallet = monero.WalletManager_openWallet(
      manager!,
      path: walletPath,
      password: '$password-incorrect',
      networkType: networkType,
    );
    if (activeWallet!.address != 0) {
      require(monero.Wallet_status(activeWallet!) != 0, 'Incorrect password was accepted.');
      closeWallet();
    } else {
      activeWallet = null;
    }

    step = 'reopen and compare identity';
    activeWallet = monero.WalletManager_openWallet(
      manager!,
      path: walletPath,
      password: password,
      networkType: networkType,
    );
    checkWallet();
    require(monero.Wallet_address(activeWallet!) == address, 'Reopened wallet address changed.');
    require(monero.Wallet_seed(activeWallet!, seedOffset: '') == seed, 'Reopened wallet seed changed.');
    closeWallet();

    stdout.writeln('$_resultPrefix${jsonEncode({
      'ok': true,
      'network': 'testnet',
      'abiMatched': true,
      'created': true,
      'stored': true,
      'wrongPasswordRejected': true,
      'reopened': true,
      'addressAndSeedPreserved': true,
      'networkOperations': false,
    })}');
  } catch (_) {
    // Step names are controlled strings; never log exceptions that might
    // contain native wallet material or a password from a third-party library.
    stdout.writeln('$_resultPrefix${jsonEncode({'ok': false, 'step': step})}');
    exitCode = 1;
  } finally {
    if (activeWallet != null && activeWallet!.address != 0 && manager != null) {
      try {
        closeWallet();
      } catch (_) {
        exitCode = 1;
      }
    }
  }
}
