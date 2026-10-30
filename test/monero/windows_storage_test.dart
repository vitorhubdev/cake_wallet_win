import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:cw_monero/api/account_list.dart' as account;
import 'package:cw_monero/api/wallet.dart' as wallet;
import 'package:monero/monero.dart' as native;
import 'package:monero/src/monero.dart' as wrappers;

void main() {
  final bundle = Platform.environment['CAKE_MONERO_TEST_BUNDLE'];
  group('packaged Windows Monero storage API', () {
    late Directory temporary;
    late String walletPath;
    late String password;
    late Pointer<Void> manager;
    Pointer<Void>? current;
    late String previousDirectory;

    setUp(() {
      previousDirectory = Directory.current.path;
      Directory.current = bundle!;
      native.libPath = '$bundle${Platform.pathSeparator}libmonero_wallet2_api_c.dll';
      native.printStarts = false;
      native.WalletManagerFactory_setLogLevel(-1);
      temporary = Directory.systemTemp.createTempSync('cake-storage-teste-');
      final directory = Directory('${temporary.path}/carteira com espaço')..createSync();
      walletPath = '${directory.path}/testnet';
      password = List.generate(32, (_) => Random.secure().nextInt(256).toRadixString(16)).join();
      manager = native.WalletManagerFactory_getWalletManager();
      current = native.WalletManager_createWallet(manager, path: walletPath,
          password: password, language: 'English', networkType: 1);
      expect(current!.address, isNot(0));
      expect(native.Wallet_status(current!), 0);
      native.Wallet_setOffline(current!, offline: true);
      account.currentWallet = wrappers.MoneroWallet(current!);
    });
    tearDown(() async {
      await wallet.walletStoreQueue.idle;
      account.currentWallet = null;
      if (current != null) {
        final pointer = current!;
        current = null;
        expect(native.WalletManager_closeWallet(manager, pointer, false), isTrue);
      }
      Directory.current = previousDirectory;
      await temporary.delete(recursive: true);
    });
    test('awaited concurrent saves persist metadata before reopen', () async {
      native.Wallet_setCacheAttribute(current!, key: 'cake.stability.probe', value: 'persisted');
      final backupStarted = Completer<void>();
      final releaseBackup = Completer<void>();
      final first = wallet.store(afterStore: () async {
        backupStarted.complete();
        await releaseBackup.future;
      });
      var secondFinished = false;
      final second = wallet.store().then((_) => secondFinished = true);
      await backupStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(secondFinished, isFalse);
      releaseBackup.complete();
      await Future.wait([first, second, wallet.store()]);
      final pointer = current!;
      current = null;
      account.currentWallet = null;
      expect(native.WalletManager_closeWallet(manager, pointer, false), isTrue);
      current = native.WalletManager_openWallet(manager, path: walletPath, password: password, networkType: 1);
      expect(native.Wallet_status(current!), 0);
      account.currentWallet = wrappers.MoneroWallet(current!);
      expect(native.Wallet_getCacheAttribute(current!, key: 'cake.stability.probe'), 'persisted');
    });
    test('a stale queued write fails without poisoning later saves', () async {
      final hold = Completer<void>();
      final blocking = wallet.walletStoreQueue.run(() => hold.future);
      final stale = wallet.store();
      final expectation = expectLater(stale, throwsStateError);
      account.currentWallet = null;
      hold.complete();
      await blocking;
      await expectation;
      account.currentWallet = wrappers.MoneroWallet(current!);
      await wallet.store();
      expect(File(walletPath).existsSync(), isTrue);
    });
  }, skip: !Platform.isWindows || bundle == null);
}
