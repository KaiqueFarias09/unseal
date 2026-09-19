import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// Regression: empty input must fail with a typed [UnsealException].
///
/// Found by the fuzz invariants sweep: `Unseal.read`
/// threw `EmptyBytesException`, which used to implement `Exception`
/// directly — outside the library's typed-error contract. Callers
/// catching `UnsealException` (the documented contract for corrupt
/// input) would have missed it.
void main() {
  test('empty input throws an UnsealException from every entry point', () async {
    final bytes = Uint8List(0);
    final emptyInput = allOf(isA<UnsealException>(), isA<EmptyBytesException>());

    expect(() => Unseal.parse(bytes), throwsA(isA<UnsealException>()));
    expect(() => Unseal.readMetadataSync(bytes), throwsA(isA<UnsealException>()));
    await expectLater(Unseal.read(bytes), throwsA(emptyInput));
    await expectLater(Unseal.readMetadata(bytes), throwsA(isA<UnsealException>()));
  });
}
