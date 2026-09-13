import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

/// Regression: empty input must fail with a TYPED [ELivreException].
///
/// Found by the fuzz invariants sweep: `BookReader.openFromBytes`
/// threw `EmptyBytesException`, which used to implement `Exception`
/// directly — outside the library's typed-error contract. Callers
/// catching `ELivreException` (the documented contract for corrupt
/// input) would have missed it.
void main() {
  test('empty input throws an ELivreException from every entry point', () {
    final bytes = Uint8List(0);
    // Sync parse goes through detection first (empty input is
    // unrecognized, typed)…
    expect(() => BookReader.parseBook(bytes), throwsA(isA<ELivreException>()));
    expect(() => BookReader.readMetadataSync(bytes), throwsA(isA<ELivreException>()));
    // …while the async readers reject empty bytes up front.
    expect(() => BookReader.openFromBytes(bytes), throwsA(isA<ELivreException>()));
    expect(() => BookReader.openFromBytes(bytes), throwsA(isA<EmptyBytesException>()));
    expect(() => BookReader.readMetadataFromBytes(bytes), throwsA(isA<ELivreException>()));
  });
}
