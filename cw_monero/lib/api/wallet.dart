import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:cw_monero/api/account_list.dart';
import 'package:cw_monero/api/exceptions/setup_wallet_exception.dart';
import 'package:cw_monero/api/get_all_unspent.dart';
import "package:cw_monero/exceptions/monero_exceptions.dart";
import 'package:monero/monero.dart' as monero;
import 'package:cw_core/utils/async_serial_queue.dart';
import 'package:cw_monero/api/sync_polling.dart';
import 'package:polyseed/polyseed.dart';

bool debugMonero = false;

int getSyncingHeight() {
  // final height = monero.MONERO_cw_WalletListener_height(getWlptr());
  if (currentWallet == null) return 0;
  final h2 = currentWallet!.blockChainHeight();
  // printV("height: $height / $h2");
  return h2;
}

bool isNeededToRefresh() {
  final wl = getWlptr();
  if (wl == null) return false;
  final ret = wl.isNeedToRefresh();
  wl.resetNeedToRefresh();
  return ret;
}

bool isNewTransactionExist() {
  final wlptr = getWlptr();
  if (wlptr == null) return false;
  final ret = wlptr.isNewTransactionExist();
  wlptr.resetIsNewTransactionExist();
  return ret;
}

String getFilename() => currentWallet!.filename();

String getSeed() {
  // monero.Wallet_setCacheAttribute(wptr!, key: "cakewallet.seed", value: seed);
  final cakepolyseed = currentWallet!.getCacheAttribute(key: "cakewallet.seed");
  final cakepassphrase = getPassphrase();

  final weirdPolyseed = currentWallet!.getPolyseed(passphrase: cakepassphrase);
  if (weirdPolyseed != "") return weirdPolyseed;

  if (cakepolyseed != "") {
    if (cakepassphrase != "") {
      try {
        final lang = PolyseedLang.getByPhrase(cakepolyseed);
        final coin = PolyseedCoin.POLYSEED_MONERO;
        final ps = Polyseed.decode(cakepolyseed, lang, coin);
        if (ps.isEncrypted || cakepassphrase == "") return ps.encode(lang, coin);
        ps.crypt(cakepassphrase);
        return ps.encode(lang, coin);
      } catch (e) {
        printV(e);
      }
    }
    return cakepolyseed;
  }

  final bip39 = currentWallet!.getCacheAttribute(key: "cakewallet.seed.bip39");

  if (bip39.isNotEmpty) return bip39;

  final legacy = getSeedLegacy(null);
  return legacy;
}

String? getSeedLanguage(String? language) {
  switch (language) {
    case "Chinese (Traditional)":
      language = "Chinese (simplified)";
      break;
    case "Chinese (Simplified)":
      language = "Chinese (simplified)";
      break;
    case "Korean":
      language = "English";
      break;
    case "Czech":
      language = "English";
      break;
    case "Japanese":
      language = "English";
      break;
  }
  return language;
}

String getSeedLegacy(String? language) {
  final cakepassphrase = getPassphrase();
  language = getSeedLanguage(language);
  var legacy = currentWallet!.seed(seedOffset: cakepassphrase);
  if (currentWallet!.status() != 0) {
    if (currentWallet!.errorString().contains("seed_language")) {
      currentWallet!.setSeedLanguage(language: "English");
      legacy = currentWallet!.seed(seedOffset: cakepassphrase);
    }
  }

  if (language != null) {
    currentWallet!.setSeedLanguage(language: language);
    final status = currentWallet!.status();
    if (status != 0) {
      final err = currentWallet!.errorString();
      if (legacy.isNotEmpty) {
        return "$err\n\n$legacy";
      }
      return err;
    }
    legacy = currentWallet!.seed(seedOffset: cakepassphrase);
  }

  if (currentWallet!.status() != 0) {
    final err = currentWallet!.errorString();
    if (legacy.isNotEmpty) {
      return "$err\n\n$legacy";
    }
    return err;
  }
  return legacy;
}

String getPassphrase() => currentWallet?.getCacheAttribute(key: "cakewallet.passphrase") ?? "";

Map<int, Map<int, Map<int, String>>> addressCache = {};

String getAddress({int accountIndex = 0, int addressIndex = 0}) {
  // this is a workaround for when we switch the wallet pointer,
  // it should never reach UI but should be good enough to prevent gray screen
  // or other errors because of forced null check.
  if (currentWallet == null) return "<wallet not ready ($accountIndex:$addressIndex)>";

  // printV("getaddress: ${accountIndex}/${addressIndex}: ${monero.Wallet_numSubaddresses(wptr!, accountIndex: accountIndex)}: ${monero.Wallet_address(wptr!, accountIndex: accountIndex, addressIndex: addressIndex)}");
  // this could be a while loop, but I'm in favor of making it if to not cause freezes
  if (currentWallet!.numSubaddresses(accountIndex: accountIndex) - 1 < addressIndex) {
    if (currentWallet!.numSubaddressAccounts() < accountIndex) {
      currentWallet!.addSubaddressAccount();
    } else {
      currentWallet!.addSubaddress(accountIndex: accountIndex);
    }
  }
  addressCache[currentWallet!.ffiAddress()] ??= {};
  addressCache[currentWallet!.ffiAddress()]![accountIndex] ??= {};
  addressCache[currentWallet!.ffiAddress()]![accountIndex]![addressIndex] ??=
      currentWallet!.address(accountIndex: accountIndex, addressIndex: addressIndex);
  return addressCache[currentWallet!.ffiAddress()]![accountIndex]![addressIndex]!;
}

Money getFullBalance({int accountIndex = 0}) =>
    Money.fromInt(currentWallet?.balance(accountIndex: accountIndex) ?? 0, CryptoCurrency.xmr);

Money getUnlockedBalance({int accountIndex = 0}) => Money.fromInt(
    currentWallet?.unlockedBalance(accountIndex: accountIndex) ?? 0, CryptoCurrency.xmr);

int getCurrentHeight() => currentWallet?.blockChainHeight() ?? 0;

final _nodeHeightCache = NodeHeightCache();
int _nodeGeneration = 0;

void invalidateNodeHeightCache() => _nodeGeneration++;

Future<int> _refreshNodeHeight() {
  final wallet = currentWallet;
  if (wallet == null) return Future<int>.value(0);
  final address = wallet.ffiAddress();
  return _nodeHeightCache.read((address, _nodeGeneration), () => Isolate.run(() {
    return monero.Wallet_daemonBlockChainHeight(Pointer.fromAddress(address));
  }));
}

int getNodeHeightSync() {
  final wallet = currentWallet;
  if (wallet == null) return 0;
  final cached = _nodeHeightCache.peek((wallet.ffiAddress(), _nodeGeneration));
  unawaited(_refreshNodeHeight());
  return cached;
}

bool isSynchronized() {
  final wallet = currentWallet;
  return wallet != null && monero.Wallet_synchronized(Pointer.fromAddress(wallet.ffiAddress()));
}

Future<bool> isConnected() async {
  final wptrAddress = currentWallet!.ffiAddress();
  return await Isolate.run(() => monero.Wallet_connected(Pointer.fromAddress(wptrAddress))) == 1;
}

Future<bool> setupNodeSync(
    {required String address,
    String? login,
    String? password,
    bool useSSL = false,
    bool isLightWallet = false,
    String? socksProxyAddress}) async {
  final wallet = currentWallet;
  if (wallet == null) throw SetupWalletException(message: 'No active Monero wallet.');
  final addr = wallet.ffiAddress();
  invalidateNodeHeightCache();
  // Never print node credentials or a proxy URI that could contain credentials.
  printV("init: start");
  await Isolate.run(() {
    monero.Wallet_init(Pointer.fromAddress(addr),
        daemonAddress: address,
        useSsl: useSSL,
        proxyAddress: socksProxyAddress ?? '',
        daemonUsername: login ?? '',
        daemonPassword: password ?? '');
  });
  printV("init: end");

  if (currentWallet?.ffiAddress() != addr) return false;
  final status = wallet.status();

  if (status != 0) {
    final error = wallet.errorString();
    if (error != "no tx keys found for this txid") {
      printV("Monero node initialization returned an error.");
      throw SetupWalletException(message: error);
    }
  }

  if (true) {
    wallet.init3(
      argv0: '',
      defaultLogBaseName: 'moneroc',
      console: true,
      logPath: '',
    );
  }

  return status == 0;
}

void startRefreshSync() {
  currentWallet!.startRefresh();
}

void setRefreshFromBlockHeight({required int height}) {
  currentWallet!.setRefreshFromBlockHeight(refresh_from_block_height: height);
}

void setRecoveringFromSeed({required bool isRecovery}) {
  currentWallet!.setRecoveringFromSeed(recoveringFromSeed: isRecovery);
  currentWallet!.store();
}

// A failed disk write must not leave a permanently acquired mutex. Keep errors
// visible to explicit callers, while allowing the next write to proceed.
final walletStoreQueue = AsyncSerialQueue();

void refresh() {
  currentWallet!.refresh();
}

int lastStorePointer = 0;
int lastStoreHeight = 0;
DateTime? _lastStoreAt;

// A separate function scope keeps the UI/backup callback out of the isolate
// message. A nested closure can otherwise capture an unsendable ReceivePort,
// Timer or widget state from the caller even when it only references address.
Future<bool> _storeNativeWallet(int address) =>
    Isolate.run(() => monero.Wallet_store(Pointer.fromAddress(address)));

Future<void> storeSync({bool force = false, Future<void> Function()? afterStore}) {
  final wallet = currentWallet;
  if (wallet == null) return Future<void>.error(StateError('No active Monero wallet.'));
  final address = wallet.ffiAddress();
  return walletStoreQueue.run(() async {
    if (currentWallet?.ffiAddress() != address) {
      throw StateError('The active Monero wallet changed before storage.');
    }
    final height = wallet.blockChainHeight();
    final lastStoreAt = _lastStoreAt;
    if (!force && lastStorePointer == address && height >= lastStoreHeight &&
        height - lastStoreHeight < 5000 && lastStoreAt != null &&
        !DateTime.now().isBefore(lastStoreAt) &&
        DateTime.now().difference(lastStoreAt) < const Duration(minutes: 1)) {
      return;
    }
    final stored = await _storeNativeWallet(address);
    if (!stored) throw MoneroWalletException('Could not save the Monero wallet. Check disk space and file permissions.');
    // A failed write must not advance the checkpoint or suppress a later retry.
    lastStorePointer = address;
    lastStoreHeight = height;
    _lastStoreAt = DateTime.now();
    if (afterStore != null && currentWallet?.ffiAddress() == address) {
      await afterStore();
    }
  });
}

/// Background persistence never converts an already-broadcast transaction into
/// a failed payment. Explicit saves use [store] and surface storage failures.
Future<void> storeInBackground({bool force = true}) async {
  try {
    await storeSync(force: force);
  } catch (_) {
    printV('Monero background storage failed; an explicit save is required.');
  }
}

void setPasswordSync(String password) {
  currentWallet!.setPassword(password: password);

  final status = currentWallet!.status();
  if (status != 0) {
    throw MoneroWalletException(currentWallet!.errorString());
  }
}

void closeCurrentWallet() {
  currentWallet!.stop();
}

String getSecretViewKey() => currentWallet?.secretViewKey() ?? "";

String getPublicViewKey() => currentWallet?.publicViewKey() ?? "";

String getSecretSpendKey() => currentWallet?.secretSpendKey() ?? "";

String getPublicSpendKey() => currentWallet?.publicSpendKey() ?? "";

class SyncListener {
  SyncListener(this.onNewBlock, this.onNewTransaction)
      : _walletAddress = currentWallet?.ffiAddress() ?? 0,
        _nodeEpoch = _nodeGeneration {
    _poller = SessionPoller<_SyncSnapshot>(
      read: _read,
      onData: _emit,
      isActive: () => _walletAddress != 0 && _nodeEpoch == _nodeGeneration &&
          currentWallet?.ffiAddress() == _walletAddress,
      onError: (_, __) => printV('Monero synchronization status polling failed.'),
    );
    _poller.start();
  }

  final void Function(int, int, double) onNewBlock;
  final void Function() onNewTransaction;
  final int _walletAddress;
  final int _nodeEpoch;
  late final SessionPoller<_SyncSnapshot> _poller;
  int _initialSyncHeight = 0;
  int _lastKnownBlockHeight = 0;
  int _lastKnownNodeHeight = 0;
  int _ticksSinceEmit = 0;

  Future<_SyncSnapshot> _read() async {
    final newTransaction = isNewTransactionExist();
    final height = max(getSyncingHeight(), 0);
    if (_initialSyncHeight <= 0) _initialSyncHeight = height;
    final nodeHeight = await getNodeHeight();
    return _SyncSnapshot(height, nodeHeight, newTransaction);
  }

  void _emit(_SyncSnapshot snapshot) {
    if (snapshot.newTransaction) onNewTransaction();
    if (snapshot.nodeHeight <= 0) return;
    _ticksSinceEmit++;
    if (snapshot.height == _lastKnownBlockHeight &&
        snapshot.nodeHeight == _lastKnownNodeHeight && _ticksSinceEmit < 5) return;
    _ticksSinceEmit = 0;
    _lastKnownBlockHeight = snapshot.height;
    _lastKnownNodeHeight = snapshot.nodeHeight;
    final target = max(snapshot.nodeHeight, snapshot.height);
    final left = target - snapshot.height;
    final track = target - _initialSyncHeight;
    final progress = track <= 0 ? (left == 0 ? 1.0 : 0.0)
        : ((snapshot.height - _initialSyncHeight) / track).clamp(0.0, 1.0).toDouble();
    onNewBlock(snapshot.height, left, progress);
  }

  void stop() => _poller.stop();
}

class _SyncSnapshot {
  const _SyncSnapshot(this.height, this.nodeHeight, this.newTransaction);
  final int height;
  final int nodeHeight;
  final bool newTransaction;
}

SyncListener setListeners(
    void Function(int, int, double) onNewBlock, void Function() onNewTransaction) {
  final listener = SyncListener(onNewBlock, onNewTransaction);
  // setListenerNative();
  return listener;
}

void onStartup() {}

Future<bool> _setupNodeSync(Map<String, Object?> args) async {
  final address = args['address'] as String;
  final login = (args['login'] ?? '') as String;
  final password = (args['password'] ?? '') as String;
  final useSSL = args['useSSL'] as bool;
  final isLightWallet = args['isLightWallet'] as bool;
  final socksProxyAddress = (args['socksProxyAddress'] ?? '') as String;

  return setupNodeSync(
      address: address,
      login: login,
      password: password,
      useSSL: useSSL,
      isLightWallet: isLightWallet,
      socksProxyAddress: socksProxyAddress);
}

void startRefresh() => startRefreshSync();

Future<void> store({bool force = true, Future<void> Function()? afterStore}) =>
    storeSync(force: force, afterStore: afterStore);

Future<int> getNodeHeight() => _refreshNodeHeight();

void rescanBlockchainAsync() => currentWallet!.rescanBlockchainAsync();

String getSubaddressLabel(int accountIndex, int addressIndex) {
  return currentWallet!.getSubaddressLabel(accountIndex: accountIndex, addressIndex: addressIndex);
}

Future setTrustedDaemon(bool trusted) async => currentWallet!.setTrustedDaemon(arg: trusted);

Future<bool> trustedDaemon() async => currentWallet!.trustedDaemon();

String signMessage(String message, {String address = ""}) =>
    currentWallet!.signMessage(message: message, address: address);

bool verifyMessage(String message, String address, String signature) =>
    currentWallet!.verifySignedMessage(message: message, address: address, signature: signature);

Map<String, List<int>> debugCallLength() => monero.debugCallLength;

Map<String, dynamic> getWalletCacheDebug() {
  try {
    final jsonString =
        monero.MONERO_Wallet_serializeCacheToJson(Pointer.fromAddress(currentWallet!.ffiAddress()));
    final blob = json.decode(jsonString);
    blob['cake:unspent'] = getAllUnspent();
    return blob;
  } catch (e) {
    return {
      "error": e.toString(),
    };
  }
}
