import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// Regression: empty input must fail with a TYPED [UnsealException].
///
/// Found by the fuzz invariants sweep: `Unseal.read`
/// threw `EmptyBytesException`, which used to implement `Exception`
/// directly — outside the library's typed-error contract. Callers
/// catching `UnsealException` (the documented contract for corrupt
/// input) would have missed it.
void main() {
  test('empty input throws an UnsealException from every entry point', () {
    final bytes = Uint8List(0);
    // Sync parse goes through detection first (empty input is
    // unrecognized, typed)…
    expect(() => Unseal.parse(bytes), throwsA(isA<UnsealException>()));
    expect(() => Unseal.readMetadataSync(bytes), throwsA(isA<UnsealException>()));
    // …while the async readers reject empty bytes up front.
    expect(() => Unseal.read(bytes), throwsA(isA<UnsealException>()));
    expect(() => Unseal.read(bytes), throwsA(isA<EmptyBytesException>()));
    expect(() => Unseal.readMetadata(bytes), throwsA(isA<UnsealException>()));
  });
}
