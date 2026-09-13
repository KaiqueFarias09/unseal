import 'dart:convert';
import 'dart:typed_data';

import 'seeded_random.dart';
import 'zip_builder.dart';

/// A generated EPUB's structural knobs.
final class EpubSpec {
  const EpubSpec({
    required this.title,
    required this.author,
    required this.chapters,
    this.epub3 = false,
    this.withNcx = true,
    this.withNav = false,
    this.coverPng,
    this.language = 'en',
    this.uid = 'urn:uuid:00000000-0000-0000-0000-000000000000',
  });

  /// Book title string (synthetic for generated fixtures).
  final String title;

  /// Author string (synthetic for generated fixtures).
  final String author;

  /// Chapter XHTML payloads, in spine order.
  final List<String> chapters;

  /// OPF `version="3.0"` when true, otherwise `"2.0"`.
  final bool epub3;

  /// Whether to include a NCX table of contents.
  final bool withNcx;

  /// Whether to include an EPUB 3 nav document (implies [epub3] shapes).
  final bool withNav;

  /// Optional cover image bytes added as `cover.png` + cover-image manifest item.
  final Uint8List? coverPng;

  /// DC language.
  final String language;

  /// Unique identifier.
  final String uid;
}

/// Builds a structurally valid EPUB container: `mimetype` stored first
/// and uncompressed, META-INF/container.xml pointing at the OPF, the
/// OPF itself, chapters, and optional NCX/nav/cover.
Uint8List buildEpub(final EpubSpec spec) {
  final opf = _opf(spec);
  final entries = <ZipEntrySpec>[
    ZipEntrySpec('mimetype', utf8.encode(_mimeType), method: ZipMethod.stored),
    ZipEntrySpec('META-INF/container.xml', utf8.encode(_containerXml)),
    ZipEntrySpec('OEBPS/content.opf', utf8.encode(opf)),
    for (var i = 0; i < spec.chapters.length; i++)
      ZipEntrySpec('OEBPS/chapter${i + 1}.xhtml', utf8.encode(_chapterDocument(spec, i))),
    if (spec.withNcx) ZipEntrySpec('OEBPS/toc.ncx', utf8.encode(_ncx(spec))),
    if (spec.withNav) ZipEntrySpec('OEBPS/nav.xhtml', utf8.encode(_navDocument(spec))),
    if (spec.coverPng != null) ZipEntrySpec('OEBPS/cover.png', spec.coverPng!),
  ];
  return buildZip(entries);
}

/// Chapter document for spine index [index] (0-based), used standalone too.
String _chapterDocument(final EpubSpec spec, final int index) {
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!DOCTYPE html>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="${spec.language}">\n'
      '<head><title>${spec.title} — chapter ${index + 1}</title></head>\n'
      '<body>\n'
      '<h1>Chapter ${index + 1}</h1>\n'
      '<p id="p${index + 1}">${spec.chapters[index]}</p>\n'
      '</body>\n</html>\n';
}

String _opf(final EpubSpec spec) {
  final chapterItems = List<String>.generate(
    spec.chapters.length,
    (final i) =>
        '    <item id="ch${i + 1}" href="chapter${i + 1}.xhtml" '
        'media-type="application/xhtml+xml"/>',
  );
  final chapterRefs = List<String>.generate(
    spec.chapters.length,
    (final i) => '    <itemref idref="ch${i + 1}"/>',
  );
  final dcPrefix = 'xmlns:dc="http://purl.org/dc/elements/1.1/"';
  final coverItem = spec.coverPng == null
      ? ''
      : '\n    <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>';
  final navItem = spec.withNav
      ? '\n    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
      : '';
  final ncxItem = spec.withNcx
      ? '\n    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      : '';
  final version = spec.epub3 || spec.withNav ? '3.0' : '2.0';
  final metaBlock = spec.epub3 || spec.withNav
      ? '    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>'
      : '    <meta name="generator" content="fuzz-corpus-generator"/>';

  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<package xmlns="http://www.idpf.org/2007/opf" version="$version" unique-identifier="book-id">\n'
      '  <metadata $dcPrefix>\n'
      '    <dc:identifier id="book-id">${spec.uid}</dc:identifier>\n'
      '    <dc:title>${spec.title}</dc:title>\n'
      '    <dc:creator>${spec.author}</dc:creator>\n'
      '    <dc:language>${spec.language}</dc:language>\n'
      '$metaBlock\n'
      '  </metadata>\n'
      '  <manifest>\n'
      '${chapterItems.join('\n')}'
      '$navItem$ncxItem$coverItem\n'
      '  </manifest>\n'
      '  <spine${spec.withNcx ? ' toc="ncx"' : ''}>\n'
      '${chapterRefs.join('\n')}\n'
      '  </spine>\n'
      '</package>\n';
}

String _ncx(final EpubSpec spec) {
  final points = List<String>.generate(
    spec.chapters.length,
    (final i) =>
        '    <navPoint id="np${i + 1}" playOrder="${i + 1}">\n'
        '      <navLabel><text>Chapter ${i + 1}</text></navLabel>\n'
        '      <content src="chapter${i + 1}.xhtml"/>\n'
        '    </navPoint>',
  );
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
      '  <head>\n'
      '    <meta name="dtb:uid" content="${spec.uid}"/>\n'
      '  </head>\n'
      '  <docTitle><text>${spec.title}</text></docTitle>\n'
      '  <navMap>\n${points.join('\n')}\n  </navMap>\n'
      '</ncx>\n';
}

String _navDocument(final EpubSpec spec) {
  final items = List<String>.generate(
    spec.chapters.length,
    (final i) => '      <li><a href="chapter${i + 1}.xhtml">Chapter ${i + 1}</a></li>',
  );
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!DOCTYPE html>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n'
      '<head><title>Navigation</title></head>\n'
      '<body>\n'
      '  <nav epub:type="toc" id="toc">\n'
      '    <ol>\n${items.join('\n')}\n    </ol>\n'
      '  </nav>\n'
      '</body>\n</html>\n';
}

/// Deterministic synthetic EpubSpec for [seed]: 1-4 chapters of filler text.
EpubSpec syntheticEpubSpec(
  final int seed, {
  final bool epub3 = false,
  final bool withNcx = true,
  final bool withNav = false,
  final Uint8List? coverPng,
}) {
  final random = SeededRandom(seed);
  final chapterCount = random.between(1, 4);
  return EpubSpec(
    title: '${random.word(6)} ${random.word(5)}',
    author: '${random.word(4)} ${random.word(7)}',
    chapters: List<String>.generate(
      chapterCount,
      (final i) =>
          'Paragraph ${i + 1}: ${random.word(8)} ${random.word(6)} '
          '${random.word(9)} ${random.word(5)}.',
    ),
    epub3: epub3,
    withNcx: withNcx,
    withNav: withNav,
    coverPng: coverPng,
  );
}

const String _mimeType = 'application/epub+zip';
const String _containerXml =
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '  <rootfiles>\n'
    '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
    '  </rootfiles>\n'
    '</container>\n';
