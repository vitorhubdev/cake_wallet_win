import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _GetShortPathNameNative = Uint32 Function(
    Pointer<Utf16> source, Pointer<Utf16> destination, Uint32 capacity);
typedef _GetShortPathNameDart = int Function(
    Pointer<Utf16> source, Pointer<Utf16> destination, int capacity);

bool _isAscii(String text) => text.runes.every((codePoint) => codePoint < 128);

/// Finds a native-compatible alias without copying or moving wallet files.
///
/// The native Windows Monero backend can create wallet files in an accented
/// directory but fail to reopen them using a UTF-8 path. An available NTFS
/// short (8.3) path is a second name for the *same directory*.
///
/// Do not invent, transliterate or move paths when no ASCII alias exists.
/// Dart file operations should continue to use the original Unicode path.
String nativeMoneroWalletPath(String path) {
  if (!Platform.isWindows || _isAscii(path)) return path;

  final normalized = path.replaceAll('/', '\\');
  final separator = normalized.lastIndexOf('\\');
  if (separator < 1 || separator == normalized.length - 1) {
    throw StateError('Invalid Windows wallet path.');
  }

  final walletName = normalized.substring(separator + 1);
  if (!_isAscii(walletName)) {
    throw StateError(
      'Monero on Windows cannot safely reopen non-ASCII wallet filenames. '
      'Use an ASCII-only wallet name; existing wallet files were not changed.',
    );
  }

  final directory = normalized.substring(0, separator);
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getShortPath = kernel32.lookupFunction<
      _GetShortPathNameNative, _GetShortPathNameDart>('GetShortPathNameW');
  final input = directory.toNativeUtf16(allocator: calloc);
  try {
    final capacity = getShortPath(input, nullptr, 0);
    if (capacity == 0 || capacity > 32767) {
      throw StateError(
        'Windows could not resolve a safe native path for this wallet. '
        'The wallet files were not changed.',
      );
    }
    final buffer = calloc<Uint16>(capacity).cast<Utf16>();
    try {
      final written = getShortPath(input, buffer, capacity);
      if (written == 0 || written >= capacity) {
        throw StateError(
          'Windows could not resolve a safe native path for this wallet. '
          'The wallet files were not changed.',
        );
      }
      final shortDirectory = buffer.toDartString();
      if (!_isAscii(shortDirectory)) {
        throw StateError(
          'Windows has no ASCII-compatible short path for this wallet folder. '
          'The wallet files were not changed.',
        );
      }
      return '$shortDirectory\\$walletName';
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(input);
  }
}
