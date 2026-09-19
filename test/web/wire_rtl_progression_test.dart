@TestOn('browser')
library;

// RTL page-progression across the web worker wire.
//
// The spine's `page-progression-direction` (and the unspecified
// fallback) must survive encodeBookWire -> structured clone/JSON ->
// decodeBookWire, or the browser path silently loses the page-flow
// signal the main thread needs to flip the page-turn direction.
//
// dart2js notes honored here: records are destructured positionally
// and lists are never downcast wholesale.
//
// Run with: dart test test/web --platform chrome
import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('keeps the declared spine page-progression-direction across the wire', () {
    for (final direction in ['rtl', 'ltr']) {
      final book =
          Unseal.parse(
                _syntheticEpub(
                  language: 'ar',
                  spineAttribute: 'page-progression-direction="$direction"',
                ),
              )
              as EpubBook;

      expect(book.package.spine.pageProgressionDirection.name, direction);

      final (json, blobs) = encodeBookWire(book);
      final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

      expect(
        roundtrip.package.spine.pageProgressionDirection,
        book.package.spine.pageProgressionDirection,
        reason: direction,
      );
      expect(
        roundtrip.effectivePageProgressionDirection,
        book.effectivePageProgressionDirection,
        reason: direction,
      );
    }
  });

  test('keeps the language-inferred rtl direction across the wire', () {
    final book = Unseal.parse(_syntheticEpub(language: 'ar')) as EpubBook;

    expect(book.package.spine.pageProgressionDirection, PageProgressionDirection.unspecified);
    expect(book.effectivePageProgressionDirection, PageProgressionDirection.rtl);

    final (json, blobs) = encodeBookWire(book);
    final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

    expect(roundtrip.package.spine.pageProgressionDirection, PageProgressionDirection.unspecified);
    expect(roundtrip.effectivePageProgressionDirection, PageProgressionDirection.rtl);
  });

  test('keeps the unspecified direction across the wire', () {
    final book = Unseal.parse(_syntheticEpub(language: 'pt')) as EpubBook;

    expect(book.effectivePageProgressionDirection, PageProgressionDirection.unspecified);

    final (json, blobs) = encodeBookWire(book);
    final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

    expect(roundtrip.package.spine.pageProgressionDirection, PageProgressionDirection.unspecified);
    expect(roundtrip.effectivePageProgressionDirection, PageProgressionDirection.unspecified);
  });
}

const String _containerContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

/// Builds a minimal in-memory EPUB whose spine carries the given
/// [spineAttribute] fragment (empty for none).
Uint8List _syntheticEpub({required final String language, final String spineAttribute = ''}) {
  const chapter = '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Salam.</p></body></html>';
  final opf =
      '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    version="3.0" unique-identifier="uid">
  <metadata>
    <dc:title>RTL Wire</dc:title>
    <dc:language>$language</dc:language>
    <dc:identifier id="uid">urn:uuid:rtl-wire</dc:identifier>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="nav" $spineAttribute>
    <itemref idref="ch1"/>
  </spine>
</package>
''';
  const nav = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>RTL Wire</title></head>
  <body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">Chapter One</a></li></ol></nav></body>
</html>
''';

  Uint8List utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));
  final archive = Archive()
    ..addFile(
      ArchiveFile('mimetype', 20, utf8('application/epub+zip'))..compression = CompressionType.none,
    )
    ..addFile(
      ArchiveFile(
        'META-INF/container.xml',
        utf8(_containerContent).length,
        utf8(_containerContent),
      ),
    )
    ..addFile(ArchiveFile('content.opf', utf8(opf).length, utf8(opf)))
    ..addFile(ArchiveFile('nav.xhtml', utf8(nav).length, utf8(nav)))
    ..addFile(ArchiveFile('ch1.xhtml', utf8(chapter).length, utf8(chapter)));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}
