@TestOn('browser')
library;

// Wire codec micro-benchmarks on the browser runtime (dart2js/DDC).
//
// Times [encodeBookWire] and [decodeBookWire] over a synthetic
// in-memory EPUB, mirrors of the VM measurements in
// benchmark/book_wire_benchmarks.dart, and asserts the roundtrip
// keeps the book's semantic content — including the text payloads,
// which cross the wire as String entries of the blob list instead of
// JSON-escaped map values. The numbers are printed to the test
// runner's stdout because the browser suite has no benchmark harness.
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
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

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
    <item id="css1" href="styles.css" media-type="text/css"/>
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
  <head><title>Chapter One</title><link rel="stylesheet" type="text/css" href="styles.css"/></head>
  <body><p>Hello from the wire bench.</p><img src="images/pic.jpg" alt="pic"/></body>
</html>
''';

const String _cssContent = 'body { font-family: serif; } p { margin: 0; }';

const int _iterations = 20;

Uint8List _utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

Uint8List _zip(final List<(String, Uint8List, bool)> entries) {
  final archive = Archive();
  for (final (name, bytes, store) in entries) {
    final file = ArchiveFile(name, bytes.length, bytes)
      ..compression = store ? CompressionType.none : CompressionType.deflate;
    archive.addFile(file);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List buildWireBenchEpub() => _zip([
  ('mimetype', _utf8('application/epub+zip'), true),
  ('META-INF/container.xml', _utf8(_containerContent), false),
  ('content.opf', _utf8(_opfContent), false),
  ('toc.ncx', _utf8(_ncxContent), false),
  ('styles.css', _utf8(_cssContent), false),
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
    final book = Unseal.parse(bytes) as EpubBook;

    var wire = encodeBookWire(book);
    final encodeMicros = _time(_iterations, () => wire = encodeBookWire(book));
    final (json, blobs) = wire;

    var decoded = decodeBookWire(json, blobs);
    final decodeMicros = _time(_iterations, () => decoded = decodeBookWire(json, blobs));

    var binaryBytes = 0;
    var textBytes = 0;
    var textEntries = 0;
    for (final blob in blobs) {
      if (blob is Uint8List) {
        binaryBytes += blob.length;
      } else if (blob is String) {
        textEntries++;
        textBytes += convert.utf8.encode(blob).length;
      }
    }
    final blobBytes = binaryBytes + textBytes;
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
      'wire payload: json $jsonBytes B + blobs $blobBytes B '
      '(${blobs.length - textEntries} binary + $textEntries text) = '
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
    expect(roundtrip.files.html.single.path, book.files.html.single.path);
    expect(roundtrip.files.html.single.content, book.files.html.single.content);
    expect(roundtrip.files.images.single.content, tinyJpeg);
    expect(roundtrip.spinePaths, book.spinePaths);
    expect(roundtrip.package.manifest.items.length, book.package.manifest.items.length);
    expect(roundtrip.package.spine.items, book.package.spine.items);
    expect(roundtrip.archiveEntries.length, book.archiveEntries.length);
    expect(decoded, isA<EpubBook>());
  });

  test('text bodies cross as blob-list strings, not JSON map values', () {
    final bytes = buildWireBenchEpub();
    final book = Unseal.parse(bytes) as EpubBook;
    final (json, blobs) = encodeBookWire(book);

    final filesJson = json['files'] as Map<String, Object?>;
    final htmlEntry = (filesJson['html'] as List<Object?>).single as Map<String, Object?>;
    expect(htmlEntry.containsKey('content'), isFalse, reason: 'bodies must not ride the JSON map');
    expect(htmlEntry['blob'], isA<int>());
    final textBlob = blobs[htmlEntry['blob'] as int] as String;
    expect(textBlob, book.files.html.single.content);
    expect(textBlob, contains('Hello from the wire bench.'));

    final cssEntry = (filesJson['css'] as List<Object?>).single as Map<String, Object?>;
    expect(blobs[cssEntry['blob'] as int] as String, book.files.css.single.content);
  });

  test('keeps empty text content across the wire', () {
    final book =
        Unseal.parse(_syntheticEpub(title: 'Empty Bodies', chapters: [('ch1.xhtml', '')]))
            as EpubBook;

    final (json, blobs) = encodeBookWire(book);
    final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

    expect(roundtrip.files.html.single.content, isEmpty);
    expect(roundtrip.files.html.single.path, book.files.html.single.path);
  });

  test('keeps unicode, emoji and multi-KB bodies across the wire', () {
    final body =
        '<html><body><p>Ünïcødé — 中文 📚🦋 '
        '${'lorem ipsum dolor sit amet ' * 200}</p></body></html>';
    final book =
        Unseal.parse(_syntheticEpub(title: 'Ünïcødé — 中文 📚', chapters: [('ch1.xhtml', body)]))
            as EpubBook;
    expect(book.files.html.single.content.length, greaterThan(5000));

    final (json, blobs) = encodeBookWire(book);
    final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

    expect(roundtrip.metadata.title, 'Ünïcødé — 中文 📚');
    expect(roundtrip.files.html.single.content, book.files.html.single.content);
    expect(roundtrip.navigation.title, book.navigation.title);
  });

  test('round-trips many small sections', () {
    final chapters = <(String, String)>[
      for (var i = 1; i <= 40; i++)
        ('ch$i.xhtml', '<html><body><p>Section $i body.</p></body></html>'),
    ];
    final book =
        Unseal.parse(_syntheticEpub(title: 'Many Sections', chapters: chapters)) as EpubBook;

    final (json, blobs) = encodeBookWire(book);
    final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

    expect(roundtrip.files.html, hasLength(40));
    expect(
      [for (final file in roundtrip.files.html) file.content],
      [for (final file in book.files.html) file.content],
    );
    expect(roundtrip.spinePaths, book.spinePaths);
  });

  test('round-trips a book with zero html', () {
    final book =
        Unseal.parse(
              _syntheticEpub(
                title: 'No Html',
                chapters: const [],
                styles: [('style.css', 'body{color:red}')],
              ),
            )
            as EpubBook;

    expect(book.files.html, isEmpty);
    final (json, blobs) = encodeBookWire(book);
    final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

    expect(roundtrip.files.html, isEmpty);
    expect(roundtrip.files.css.single.content, 'body{color:red}');
    expect(roundtrip.metadata.title, 'No Html');
  });
  test('keeps the package, manifest and metadata flavors', () {
    for (final version in ['2.0', '3.0']) {
      final book =
          Unseal.parse(
                _syntheticEpub(
                  title: 'Flavors $version',
                  chapters: [('ch1.xhtml', '<html><body><p>Flavor probe.</p></body></html>')],
                  version: version,
                ),
              )
              as EpubBook;

      final (json, blobs) = encodeBookWire(book);
      final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

      expect(roundtrip.package.runtimeType, book.package.runtimeType, reason: version);
      expect(
        roundtrip.package.manifest.runtimeType,
        book.package.manifest.runtimeType,
        reason: version,
      );
      expect(
        roundtrip.package.metadata.runtimeType,
        book.package.metadata.runtimeType,
        reason: version,
      );
    }
  });
}

/// Builds a minimal EPUB in memory with the given [chapters]
/// (path, body) and optional [styles], one spine entry per chapter.
Uint8List _syntheticEpub({
  required final String title,
  required final List<(String, String)> chapters,
  final List<(String, String)> styles = const <(String, String)>[],
  final String version = '2.0',
}) {
  final manifestItems = <String>[
    '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    for (final (index, _) in chapters.indexed)
      '<item id="ch$index" href="${chapters[index].$1}" media-type="application/xhtml+xml"/>',
    for (final (index, _) in styles.indexed)
      '<item id="css$index" href="${styles[index].$1}" media-type="text/css"/>',
  ];
  final opf =
      '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    version="$version" unique-identifier="uid">
  <metadata>
    <dc:title>$title</dc:title>
    <dc:language>en</dc:language>
    <dc:identifier id="uid">urn:uuid:synthetic</dc:identifier>
  </metadata>
  <manifest>${manifestItems.join()}</manifest>
  <spine toc="ncx">${chapters.indexed.map((final e) => '<itemref idref="ch${e.$1}"/>').join()}</spine>
</package>
''';
  final ncx =
      '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:synthetic"/></head>
  <docTitle><text>$title</text></docTitle>
  <navMap>${chapters.indexed.map((final e) {
        final index = e.$1;
        final href = e.$2.$1;
        return '<navPoint id="np$index" playOrder="${index + 1}">'
            '<navLabel><text>Section $index</text></navLabel>'
            '<content src="$href"/></navPoint>';
      }).join()}</navMap>
</ncx>
''';

  return _zip([
    ('mimetype', _utf8('application/epub+zip'), true),
    ('META-INF/container.xml', _utf8(_containerContent), false),
    ('content.opf', _utf8(opf), false),
    ('toc.ncx', _utf8(ncx), false),
    for (final (path, body) in chapters) (path, _utf8(body), false),
    for (final (path, css) in styles) (path, _utf8(css), false),
  ]);
}

String _perOp(final int totalMicros) {
  final micros = totalMicros / _iterations;

  return micros < 1000
      ? '${micros.toStringAsFixed(1)} µs'
      : '${(micros / 1000).toStringAsFixed(2)} ms';
}
