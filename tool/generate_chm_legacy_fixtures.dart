import 'dart:io';

import '../test/tests/chm/chm_fixture_builder.dart';

void main() {
  const output = 'test/resources/books/chm';
  Directory(output).createSync(recursive: true);
  for (final codePage in const [1251, 1252, 1256]) {
    File(
      '$output/legacy-cp$codePage.chm',
    ).writeAsBytesSync(chmLegacyCodePageFixture(codePage: codePage), flush: true);
  }
}
