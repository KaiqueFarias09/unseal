library e_livre_tests;

import 'tests/core/detection_test.dart' as detection_test;
import 'tests/core/e_book_test.dart' as e_book_test;
import 'tests/epub/metadata_test.dart' as metadata_test;
import 'tests/epub/open_book_test.dart' as open_book_test;
import 'tests/epub/package_parsing_test.dart' as package_parsing_test;
import 'tests/fb2/fb2_test.dart' as fb2_test;
import 'tests/mobi/compression_test.dart' as compression_test;
import 'tests/mobi/mobi_test.dart' as mobi_test;

void main() {
  detection_test.main();
  e_book_test.main();
  open_book_test.main();
  package_parsing_test.main();
  metadata_test.main();
  mobi_test.main();
  compression_test.main();
  fb2_test.main();
}
