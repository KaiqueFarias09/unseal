import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// Regression: deeply nested FB2 documents must fail with a typed exception.
///
/// Found by the fuzz structural sweep: ~20k nested `<section>`
/// elements overflowed the stack inside the FB2 HTML renderer's
/// recursive tree walk (uncaught StackOverflowError). The renderer now
/// rejects over-deep documents up front with [Fb2Exception].
void main() {
  test('deeply nested FB2 fails with Fb2Exception, not a crash', () {
    final deep = _deepNestedFb2(20000);

    expect(() => Unseal.parse(deep), throwsA(allOf(isA<UnsealException>(), isA<Fb2Exception>())));
  });

  test('legitimately nested FB2 still parses after the depth guard', () {
    // body > section > section > section > title/p — depth 7.
    final nested = _deepNestedFb2(3);

    expect(() => Unseal.parse(nested), returnsNormally);
  });
}

/// FB2 document nesting [depth] `<section>` elements inside its body.
Uint8List _deepNestedFb2(final int depth) {
  final body = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8"?>\n')
    ..write('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description/>')
    ..write('<body>')
    ..write('<section>' * depth)
    ..write('<p>leaf</p>')
    ..write('</section>' * depth)
    ..write('</body></FictionBook>');

  return Uint8List.fromList(body.toString().codeUnits);
}
