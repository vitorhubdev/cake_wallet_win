import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cw_mweb/generated_bindings.g.dart';
import 'package:cw_mweb/print_verbose.dart';
import 'package:ffi/ffi.dart';

String libPath = (() {
  if (Platform.isWindows) return 'mweb.dll';
  if (Platform.isMacOS) return 'mweb.dylib';
  if (Platform.isIOS) return 'Mwebd.framework/Mwebd';
  if (Platform.isAndroid) return 'libmweb.so';
  return 'libmweb.so';
})();

class MWebFfi {
  final MWebFlutter lib;
  final void Function(Pointer<Char>) _freeNativeString;

  MWebFfi() : this._(DynamicLibrary.open(libPath));

  MWebFfi._(DynamicLibrary library)
      : lib = MWebFlutter(library),
        // C.CString uses the DLL's C allocator. ffi's malloc/calloc use
        // CoTaskMemAlloc/CoTaskMemFree on Windows, so the DLL must free its own
        // strings there. Keep compatibility with existing native builds on
        // the other platforms, where ffi uses the process C allocator.
        _freeNativeString = Platform.isWindows
            ? library.lookupFunction<Void Function(Pointer<Char>), void Function(Pointer<Char>)>(
                'FreeString')
            : ((pointer) => malloc.free(pointer));

  static MWebFfi instance = MWebFfi();

  int start(String dataDir, String nodeUri) {
    final chain = "".toNativeUtf8().cast<Char>();
    final dataDir_ = dataDir.toNativeUtf8().cast<Char>();
    final nodeUri_ = nodeUri.toNativeUtf8().cast<Char>();
    final errMsgPtr = calloc<Pointer<Char>>();

    try {
      final port = lib.StartServer(chain, dataDir_, nodeUri_, errMsgPtr);
      if (port == 0) {
        final errMsg = errMsgPtr.value == nullptr
            ? 'Native MWEB server returned no error message'
            : errMsgPtr.value.cast<Utf8>().toDartString();
        printV('Error starting server: $errMsg');
      }
      return port;
    } finally {
      if (errMsgPtr.value != nullptr) {
        _freeNativeString(errMsgPtr.value);
      }
      malloc.free(chain);
      malloc.free(dataDir_);
      malloc.free(nodeUri_);
      calloc.free(errMsgPtr);
    }
  }

  void stop() => lib.StopServer();

  String addresses(Uint8List scanSecret, Uint8List spendPub, int fromIndex, int toIndex) {
    final scanSecretPtr = malloc.allocate<Uint8>(scanSecret.length);
    for (int k = 0; k < scanSecret.length; k++) {
      scanSecretPtr[k] = scanSecret[k];
    }

    final spendPubKeyPtr = malloc.allocate<Uint8>(spendPub.length);
    for (int k = 0; k < spendPub.length; k++) {
      spendPubKeyPtr[k] = spendPub[k];
    }

    Pointer<Char> resultPtr = nullptr;
    try {
      resultPtr = lib.Addresses(
        scanSecretPtr.cast(),
        scanSecret.length,
        spendPubKeyPtr.cast(),
        spendPub.length,
        fromIndex,
        toIndex,
      );
      if (resultPtr == nullptr) {
        throw StateError('Native MWEB address generation returned a null pointer');
      }
      return resultPtr.cast<Utf8>().toDartString();
    } finally {
      if (resultPtr != nullptr) {
        _freeNativeString(resultPtr);
      }
      malloc.free(scanSecretPtr);
      malloc.free(spendPubKeyPtr);
    }
  }
}
