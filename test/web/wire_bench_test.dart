@TestOn('browser')
library;

// Wire codec micro-benchmarks on the browser runtime (dart2js/DDC).
//
// Times [encodeBookWire] and [decodeBookWire] over a synthetic
// in-memory EPUB, mirrors of the VM measurements in
// benchmark/book_wire_benchmarks.dart, and asserts the roundtrip
// keeps the book's semantic content. The numbers are printed to the
// test runner's stdout because the browser suite has no benchmark
// harness.
//
// dart2js notes honored here: records are destructured positionally
// (named-field patterns fail to compile) and lists are never
// downcast wholesale (elements are used through the typed decode
// results instead).
//
// Run with: dart test test/web --platform chrome
import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';
import 'package:test/test.dart';

import '../tests/mobi/mobi_fixture_builder.dart' show tinyJpeg;

const String _opfContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    version="2.0" unique-identifier="uid">
  <metadata>
    <dc:title>Wire Bench</dc:title>
    <dc:creator>Wire Author</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="uid">urn:uuid:wire-bench</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="img1" href="images/pic.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
  </spine>
</package>
''';

const String _containerContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const String _ncxContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:wire-bench"/></head>
  <docTitle><text>Wire Bench</text></docTitle>
  <navMap>
    <navPoint id="np1" playOrder="1" class="chapter">
      <navLabel><text>Chapter One</text></navLabel>
      <content src="ch1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
''';

const String _chapterContent = '''
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter One</title></head>
  <body><p>Hello from the wire bench.</p><img src="images/pic.jpg" alt="pic"/></body>
</html>
''';

const int _iterations = 20;

Uint8List _utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

Uint8List _zip(final List<(String, Uint8List, bool)> entries) {
  final archive = Archive();
  for (final (name, bytes, store) in entries) {
    final file = ArchiveFile(name, bytes.length, bytes)..compress = !store;
    archive.addFile(file);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive) ?? <int>[]);
}

Uint8List buildWireBenchEpub() => _zip([
  ('mimetype', _utf8('application/epub+zip'), true),
  ('META-INF/container.xml', _utf8(_containerContent), false),
  ('content.opf', _utf8(_opfContent), false),
  ('toc.ncx', _utf8(_ncxContent), false),
  ('ch1.xhtml', _utf8(_chapterContent), false),
  ('images/pic.jpg', tinyJpeg, false),
]);

/// Times [action] over [iterations] runs (one untimed warm-up first)
/// and returns the total elapsed microseconds.
int _time(final int iterations, final void Function() action) {
  action(); // Warm-up (JIT / script caching).
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    action();
  }
  watch.stop();

  return watch.elapsedMicroseconds;
}

void main() {
  test('wire codec benchmarks on the browser runtime', () {
    final bytes = buildWireBenchEpub();
    final book = BookReader.parseBook(bytes) as EpubBook;

    var wire = encodeBookWire(book);
    final encodeMicros = _time(_iterations, () => wire = encodeBookWire(book));
    final (json, blobs) = wire;

    var decoded = decodeBookWire(json, blobs);
    final decodeMicros = _time(_iterations, () => decoded = decodeBookWire(json, blobs));

    var blobBytes = 0;
    for (final blob in blobs) {
      blobBytes += blob.length;
    }
    final jsonBytes = convert.utf8.encode(encodeJson(json)).length;
    final wireBytes = jsonBytes + blobBytes;
    final factor = (wireBytes / bytes.length).toStringAsFixed(2);

    // The framework surfaces stdout, so the numbers ride along with
    // the test report.
    // ignore: avoid_print, the browser runner has no benchmark harness
    print(
      'Web wire codec — browser runtime — synthetic EPUB '
      '${bytes.length} B, $_iterations iterations',
    );
    // ignore: avoid_print, the browser runner has no benchmark harness
    print(
      'encodeBookWire: ${_perOp(encodeMicros)} per op '
      '(total ${encodeMicros / 1000} ms)',
    );
    // ignore: avoid_print, the browser runner has no benchmark harness
    print(
      'decodeBookWire: ${_perOp(decodeMicros)} per op '
      '(total ${decodeMicros / 1000} ms)',
    );
    // ignore: avoid_print, the browser runner has no benchmark harness
    print(
      'wire payload: json $jsonBytes B + blobs $blobBytes B = '
      '$wireBytes B ($factor× file)',
    );

    // Roundtrip sanity: the decoded book must carry the source's
    // semantic content, including through the JSON string channel the
    // worker transport actually uses.
    final channel = decodeJson(encodeJson(json));
    final roundtrip = decodeBookWire(channel, blobs) as EpubBook;

    expect(roundtrip.format, BookFormat.epub);
    expect(roundtrip.metadata.title, book.metadata.title);
    expect(roundtrip.metadata.authors, book.metadata.authors);
    expect(roundtrip.navigation.navPoints.single.label, 'Chapter One');
    expect(roundtrip.files.html.single.content, contains('Hello from the wire bench.'));
    expect(roundtrip.files.images.single.content, tinyJpeg);
    expect(roundtrip.spinePaths, book.spinePaths);
    expect(roundtrip.package.manifest.items.length, book.package.manifest.items.length);
    expect(roundtrip.package.spine.items, book.package.spine.items);
    expect(roundtrip.archiveEntries.length, book.archiveEntries.length);
    expect(decoded, isA<EpubBook>());
  });
}

String _perOp(final int totalMicros) {
  final micros = totalMicros / _iterations;

  return micros < 1000
      ? '${micros.toStringAsFixed(1)} µs'
      : '${(micros / 1000).toStringAsFixed(2)} ms';
}
