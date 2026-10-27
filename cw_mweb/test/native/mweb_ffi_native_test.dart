import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cw_mweb/mweb_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

// This suite loads the actual Go library and runs without a node or funds.
// CI must set MWEB_NATIVE_TEST_LIBRARY to the absolute built DLL path.
void main() {
  final nativeLibraryPath = Platform.environment['MWEB_NATIVE_TEST_LIBRARY'];

  group('MWEB native string ownership', () {
    late MWebFfi mweb;
    late Directory temporaryDirectory;

    setUpAll(() {
      libPath = nativeLibraryPath!;
      mweb = MWebFfi();
      temporaryDirectory = Directory.systemTemp.createTempSync('cake-mweb-native-');
    });

    tearDownAll(() {
      mweb.stop();
      temporaryDirectory.deleteSync(recursive: true);
    });

    test('repeated address generation releases DLL-owned strings', () {
      final scanSecret = Uint8List(32)..[31] = 1;
      // Compressed secp256k1 generator public key, a public test vector.
      const publicKeyHex =
          '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
      final spendPublicKey = Uint8List.fromList([
        for (var i = 0; i < publicKeyHex.length; i += 2)
          int.parse(publicKeyHex.substring(i, i + 2), radix: 16),
      ]);
      // Reference output verified with the same pinned Go MWEB implementation
      // on Linux; the Windows DLL must return the same public addresses.
      const expected =
          'ltcmweb1qqd07msaafemltuul7fw7mn5w9dlaukv49ntzqrpxprq34xyf09agsq6lahpm6nnh7heelujaah8gu2mlmeve2txkyqxzvzxpr2vgj7t63qnts8hx,'
          'ltcmweb1qqv3lcgxf67aja9fpwzywmrr6xxtyscxywkshpyw5d3mt7u8z3me0wqerlssvn4am962jzuygakx85vvkfpsvgadpwzgagmrkhacw9rhj7ux0g5cz';
      expect(mweb.addresses(scanSecret, spendPublicKey, 0, 2), expected);
      final addresses = expected.split(',');
      expect(addresses, hasLength(2));
      expect(addresses.first, isNot(addresses.last));
      expect(addresses.every((address) => address.length > 50), isTrue);

      for (var i = 0; i < 256; i++) {
        expect(mweb.addresses(scanSecret, spendPublicKey, 0, 2), expected);
      }
    });

    test('start failure releases the native error string', () {
      // A regular file cannot contain the daemon database, so this fails
      // before the daemon can open a connection or start syncing.
      final invalidDataDirectory = File('${temporaryDirectory.path}/not-a-directory')
        ..writeAsStringSync('native error allocation test');
      for (var i = 0; i < 16; i++) {
        expect(mweb.start(invalidDataDirectory.path, ''), 0);
        mweb.stop();
      }
    });

    test('FreeString accepts a null pointer', () {
      final freeString = DynamicLibrary.open(nativeLibraryPath!)
          .lookupFunction<Void Function(Pointer<Char>), void Function(Pointer<Char>)>('FreeString');
      freeString(nullptr);
    });
  }, skip: nativeLibraryPath == null ? 'Set MWEB_NATIVE_TEST_LIBRARY to run real native tests' : false);
}
