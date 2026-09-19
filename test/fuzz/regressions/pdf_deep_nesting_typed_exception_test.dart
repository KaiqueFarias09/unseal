import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// Regression: deep PDF object nesting must fail TYPED.
///
/// Found by the fuzz structural sweep: a PDF object made of ~20k
/// nested `[` arrays overflowed the stack inside PdfObjectParser
/// (uncaught StackOverflowError — a hard crash, not a typed failure).
/// The parser now caps nesting depth and fails with [PdfException].
void main() {
  test('deeply nested PDF arrays fail with PdfException, not a crash', () {
    final deep = _deepNestedPdf(100000);

    expect(() => Unseal.parse(deep), throwsA(isA<UnsealException>()));
    expect(() => Unseal.parse(deep), throwsA(isA<PdfException>()));
  });

  test('shallow PDF structures never trip the depth cap', () {
    // Nested three levels deep with real content — well under the
    // cap, so the failure (this minimal document has no pages) can
    // never be the nesting guard.
    final body = '[[1 2 3 (text) << /Key (value) >>]]';
    final bytes = _pdfWithObject(body);

    expect(
      () => Unseal.parse(bytes),
      throwsA(
        isA<PdfException>().having(
          (final e) => e.message,
          'message',
          isNot(contains('nesting exceeds')),
        ),
      ),
    );
  });
}

/// Minimal PDF whose first object body is [depth] nested arrays.
Uint8List _deepNestedPdf(final int depth) {
  final out = BytesBuilder(copy: false);
  out.add('%PDF-1.7\n1 0 obj\n'.codeUnits);
  out.add(Uint8List.fromList(List<int>.filled(depth, 0x5B))); // '['
  out.add(Uint8List.fromList(List<int>.filled(depth, 0x5D))); // ']'
  out.add('\nendobj\ntrailer\n<< /Size 2 /Root 1 0 R >>\n%%EOF'.codeUnits);

  return out.toBytes();
}

Uint8List _pdfWithObject(final String objectBody) {
  final out = BytesBuilder(copy: false);
  out.add('%PDF-1.7\n1 0 obj\n'.codeUnits);
  out.add(objectBody.codeUnits);
  out.add('\nendobj\ntrailer\n<< /Size 2 /Root 1 0 R >>\n%%EOF'.codeUnits);

  return out.toBytes();
}
