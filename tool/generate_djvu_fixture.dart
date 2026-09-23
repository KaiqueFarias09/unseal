import 'dart:io';

import '../test/support/djvu_fixture.dart';

void main(final List<String> args) {
  final jpeg = File('test/resources/fuzz/generated/images/tiny.jpg').readAsBytesSync();
  final generated = djvuJpegPage(jpeg, text: 'A scanned page');
  final target = File('test/resources/books/djvu/jpeg-only.djvu');
  if (args.contains('--check')) {
    if (!target.existsSync() || !_equal(target.readAsBytesSync(), generated)) {
      stderr.writeln('DjVu fixture differs from its generator.');
      exitCode = 1;
    }
    return;
  }
  target.parent.createSync(recursive: true);
  target.writeAsBytesSync(generated);
}

bool _equal(final List<int> first, final List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
