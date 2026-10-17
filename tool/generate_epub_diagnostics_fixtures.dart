import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const _outputDirectory = 'test/resources/epub/diagnostics';

/// Deterministic timestamps for every generated zip entry.
const _fixedTime = 946684800;

/// EPUB 3 base documents shared by most fixtures.
const _containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const _navXhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Table of contents</title></head>
  <body>
    <nav epub:type="toc">
      <h1>Contents</h1>
      <ol><li><a href="ch1.xhtml">Chapter 1</a></li></ol>
    </nav>
  </body>
</html>
''';

const _ch1Xhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter 1</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
  <body><h1>Chapter 1</h1><p id="intro">Diagnostics fixture chapter.</p></body>
</html>
''';

const _styleCss = 'body { font-family: serif; }\n';

String _epub3Opf({required final String manifest, required final String spine}) {
  return '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="pub-id">urn:uuid:1f0a3c5e-6d3a-4f0a-9c5e-000000000001</dc:identifier>
    <dc:title>Unseal EPUB diagnostics fixture</dc:title>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-10-17T00:00:00Z</meta>
  </metadata>
  <manifest>
$manifest  </manifest>
  <spine>
$spine  </spine>
</package>
''';
}

const _epub3ManifestBase =
    '''    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
''';

const _epub3SpineBase = '    <itemref idref="ch1"/>\n';

const _ncx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:1f0a3c5e-6d3a-4f0a-9c5e-000000000001"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>Unseal EPUB diagnostics fixture</text></docTitle>
  <navMap>
    <navPoint id="np-1" playOrder="1">
      <navLabel><text>Chapter 1</text></navLabel>
      <content src="ch1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
''';

String _epub2Opf({
  final String manifest =
      '''    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
''',
  final String spine = '    <itemref idref="ch1"/>\n',
  final String spineAttributes = ' toc="ncx"',
  final String guide = '''  <guide>
    <reference type="text" title="Beginning" href="ch1.xhtml"/>
  </guide>
''',
}) {
  return '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="pub-id" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="pub-id" opf:scheme="UUID">urn:uuid:1f0a3c5e-6d3a-4f0a-9c5e-000000000001</dc:identifier>
    <dc:title>Unseal EPUB diagnostics fixture</dc:title>
    <dc:language>en</dc:language>
    <dc:creator opf:role="aut">Unseal</dc:creator>
  </metadata>
  <manifest>
$manifest  </manifest>
  <spine$spineAttributes>
$spine  </spine>
$guide</package>
''';
}

/// EPUB 2 chapters use the OEBBS 1.1 text html content type.
const _epub2Ch1Xhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter 1</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
  <body><h1>Chapter 1</h1><p id="intro">Diagnostics fixture chapter.</p></body>
</html>
''';

Future<void> main() async {
  final directory = Directory(_outputDirectory)..createSync(recursive: true);
  final cases = <_Case>[];

  void emit(
    final String id,
    final String fileName,
    final Map<String, Object> entries, {
    required final String epubFamily,
    required final String readability,
    required final List<String> rules,
  }) {
    final bytes = _zip(entries);
    File('${directory.path}/$fileName').writeAsBytesSync(bytes, flush: true);
    cases.add(
      _Case(
        id: id,
        file: fileName,
        bytes: bytes.length,
        epubFamily: epubFamily,
        readability: readability,
        rules: rules,
      ),
    );
  }

  // ---- Valid baselines -------------------------------------------------
  emit(
    'epub3-valid',
    'epub3-valid.epub',
    _epub3Entries(),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const [],
  );
  emit(
    'epub2-valid',
    'epub2-valid.epub',
    _epub2Entries(),
    epubFamily: 'epub2',
    readability: 'readable',
    rules: const [],
  );
  emit(
    'paths-unicode-percent-valid',
    'paths-unicode-percent-valid.epub',
    _unicodeEntries(),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const [],
  );

  // ---- Container and rootfile -----------------------------------------
  emit(
    'container-missing',
    'container-missing.epub',
    _epub3Entries(withoutContainer: true),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.container.missing'],
  );
  emit(
    'container-mimetype-wrong',
    'container-mimetype-wrong.epub',
    _epub3Entries(mimetype: 'application/zip'),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.container.mimetype-invalid'],
  );
  emit(
    'rootfile-element-missing',
    'rootfile-element-missing.epub',
    _epub3Entries(
      containerXml: '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
  </rootfiles>
</container>
''',
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.container.rootfile.missing'],
  );
  emit(
    'rootfile-path-unresolved',
    'rootfile-path-unresolved.epub',
    _epub3Entries(
      containerXml: _containerXml.replaceFirst('OEBPS/content.opf', 'OEBPS/absent.opf'),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.container.rootfile.path-unresolved'],
  );
  emit(
    'rootfile-media-type-unsupported',
    'rootfile-media-type-unsupported.epub',
    _epub3Entries(
      containerXml: _containerXml.replaceFirst('application/oebps-package+xml', 'text/xml'),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.container.rootfile.media-type-unsupported'],
  );

  // ---- Package ---------------------------------------------------------
  emit(
    'package-version-unsupported',
    'package-version-unsupported.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest: _epub3ManifestBase,
        spine: _epub3SpineBase,
      ).replaceFirst('version="3.0"', 'version="9.3"'),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.package.version-unsupported'],
  );

  // ---- Manifest --------------------------------------------------------
  emit(
    'manifest-item-incomplete',
    'manifest-item-incomplete.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest: '$_epub3ManifestBase    <item id="ghost" href="ghost.png"/>\n',
        spine: _epub3SpineBase,
      ),
    ),
    epubFamily: 'epub3',
    readability: 'typed-failure',
    rules: const ['epub.manifest.item.incomplete', 'epub.manifest.resource-missing'],
  );
  emit(
    'manifest-resource-missing',
    'manifest-resource-missing.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest:
            '$_epub3ManifestBase    <item id="ghost" href="ghost.png" media-type="image/png"/>\n',
        spine: _epub3SpineBase,
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.manifest.resource-missing'],
  );
  emit(
    'manifest-id-duplicate',
    'manifest-id-duplicate.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest:
            '$_epub3ManifestBase    <item id="ch1" href="ch1-copy.xhtml" media-type="application/xhtml+xml"/>\n',
        spine: _epub3SpineBase,
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.manifest.id-duplicate', 'epub.manifest.resource-missing'],
  );
  emit(
    'manifest-href-duplicate',
    'manifest-href-duplicate.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest:
            '$_epub3ManifestBase    <item id="ch1-copy" href="ch1.xhtml" media-type="application/xhtml+xml"/>\n',
        spine: _epub3SpineBase,
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.manifest.href-duplicate'],
  );
  emit(
    'manifest-remote-resource-undeclared',
    'manifest-remote-resource-undeclared.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest:
            '$_epub3ManifestBase    <item id="remote" href="http://example.org/cover.png" media-type="image/png"/>\n',
        spine: _epub3SpineBase,
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.manifest.remote-resource-undeclared'],
  );
  emit(
    'manifest-href-fragment',
    'manifest-href-fragment.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest:
            '''    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="ch1" href="ch1.xhtml#intro" media-type="application/xhtml+xml"/>
''',
        spine: '    <itemref idref="ch1"/>\n',
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.manifest.href-fragment'],
  );

  // ---- Spine -----------------------------------------------------------
  emit(
    'spine-reference-invalid',
    'spine-reference-invalid.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest: _epub3ManifestBase,
        spine: '$_epub3SpineBase    <itemref idref="absent"/>\n',
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.spine.reference-invalid'],
  );
  emit(
    'spine-empty',
    'spine-empty.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(manifest: _epub3ManifestBase, spine: ''),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.spine.empty'],
  );
  emit(
    'spine-reference-duplicate',
    'spine-reference-duplicate.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest: _epub3ManifestBase,
        spine: '$_epub3SpineBase    <itemref idref="ch1"/>\n',
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.spine.reference-duplicate'],
  );

  // ---- Navigation (EPUB 3) --------------------------------------------
  emit(
    'nav-missing',
    'nav-missing.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest:
            '    <item id="css" href="style.css" media-type="text/css"/>\n    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>\n',
        spine: _epub3SpineBase,
      ),
      entries: {'OEBPS/ch1.xhtml': _ch1Xhtml, 'OEBPS/style.css': _styleCss},
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.navigation.nav-missing'],
  );
  emit(
    'nav-duplicate',
    'nav-duplicate.epub',
    _epub3Entries(
      contentOpf: _epub3Opf(
        manifest:
            '$_epub3ManifestBase    <item id="nav2" href="nav2.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n',
        spine: _epub3SpineBase,
      ),
      entries: {'OEBPS/nav2.xhtml': _navXhtml},
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.navigation.nav-duplicate'],
  );
  emit(
    'nav-toc-section-missing',
    'nav-toc-section-missing.epub',
    _epub3Entries(
      navXhtml: '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Navigation</title></head>
  <body>
    <nav epub:type="page-list">
      <h2>Pages</h2>
      <ol><li><a href="ch1.xhtml#intro">1</a></li></ol>
    </nav>
  </body>
</html>
''',
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.navigation.toc-missing'],
  );
  emit(
    'nav-link-unresolved',
    'nav-link-unresolved.epub',
    _epub3Entries(
      navXhtml: _navXhtml.replaceFirst(
        '<a href="ch1.xhtml">Chapter 1</a>',
        '<a href="absent.xhtml">Chapter 1</a>',
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.navigation.link-unresolved'],
  );
  emit(
    'nav-fragment-unresolved',
    'nav-fragment-unresolved.epub',
    _epub3Entries(
      navXhtml: _navXhtml.replaceFirst(
        '<a href="ch1.xhtml">Chapter 1</a>',
        '<a href="ch1.xhtml#absent">Chapter 1</a>',
      ),
    ),
    epubFamily: 'epub3',
    readability: 'readable',
    rules: const ['epub.navigation.fragment-unresolved'],
  );

  // ---- Navigation (EPUB 2) --------------------------------------------
  emit(
    'ncx-missing',
    'ncx-missing.epub',
    _epub2Entries(withoutNcx: true, spineAttributes: ' toc="ncx"'),
    epubFamily: 'epub2',
    readability: 'readable',
    rules: const ['epub.manifest.resource-missing', 'epub.navigation.toc-missing'],
  );
  emit(
    'ncx-toc-attribute-missing',
    'ncx-toc-attribute-missing.epub',
    _epub2Entries(spineAttributes: ''),
    epubFamily: 'epub2',
    readability: 'readable',
    rules: const ['epub.navigation.toc-reference-missing'],
  );
  emit(
    'ncx-link-unresolved',
    'ncx-link-unresolved.epub',
    _epub2Entries(
      ncx: _ncx.replaceFirst('<content src="ch1.xhtml"/>', '<content src="absent.xhtml"/>'),
    ),
    epubFamily: 'epub2',
    readability: 'readable',
    rules: const ['epub.navigation.link-unresolved'],
  );
  emit(
    'guide-reference-unresolved',
    'guide-reference-unresolved.epub',
    _epub2Entries(
      guide: '''  <guide>
    <reference type="text" title="Beginning" href="absent.xhtml"/>
  </guide>
''',
    ),
    epubFamily: 'epub2',
    readability: 'readable',
    rules: const ['epub.guide.reference-unresolved'],
  );

  final manifest = <String, Object?>{
    'schema_version': 1,
    'generator': 'tool/generate_epub_diagnostics_fixtures.dart',
    'regenerate': 'dart run tool/generate_epub_diagnostics_fixtures.dart',
    'provenance':
        'Synthetic deterministic fixtures generated locally for the '
        'B03 diagnostics mission; no third-party bytes. See PROVENANCE.md.',
    'rules_ref': 'doc/epub-diagnostics.md',
    'cases': [
      for (final entry in cases)
        {
          'id': entry.id,
          'file': entry.file,
          'bytes': entry.bytes,
          'sha256': _sha256(File('${directory.path}/${entry.file}').readAsBytesSync()),
          'epub_family': entry.epubFamily,
          'expected_readability': entry.readability,
          'expected_rules': entry.rules,
        },
    ],
  };
  File(
    '${directory.path}/manifest.json',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n', flush: true);

  stdout.writeln('Wrote ${cases.length} fixtures and manifest.json to $_outputDirectory');
}

class _Case {
  const _Case({
    required this.id,
    required this.file,
    required this.bytes,
    required this.epubFamily,
    required this.readability,
    required this.rules,
  });

  final String id;
  final String file;
  final int bytes;
  final String epubFamily;
  final String readability;
  final List<String> rules;
}

Map<String, Object> _epub3Entries({
  final String? containerXml,
  final String? contentOpf,
  final String? navXhtml,
  final String mimetype = 'application/epub+zip',
  final Map<String, String> entries = const {},
  final bool withoutContainer = false,
}) {
  return {
    'mimetype': mimetype,
    if (!withoutContainer) 'META-INF/container.xml': containerXml ?? _containerXml,
    'OEBPS/content.opf':
        contentOpf ?? _epub3Opf(manifest: _epub3ManifestBase, spine: _epub3SpineBase),
    'OEBPS/nav.xhtml': navXhtml ?? _navXhtml,
    'OEBPS/ch1.xhtml': _ch1Xhtml,
    'OEBPS/style.css': _styleCss,
    for (final entry in entries.entries) entry.key: entry.value,
  };
}

Map<String, Object> _epub2Entries({
  final String ncx = _ncx,
  final Map<String, String> entries = const {},
  final bool withoutNcx = false,
  final String spineAttributes = ' toc="ncx"',
  final String guide = '''  <guide>
    <reference type="text" title="Beginning" href="ch1.xhtml"/>
  </guide>
''',
}) {
  return {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': _containerXml,
    'OEBPS/content.opf': _epub2Opf(spineAttributes: spineAttributes, guide: guide),
    if (!withoutNcx) 'OEBPS/toc.ncx': ncx,
    'OEBPS/ch1.xhtml': _epub2Ch1Xhtml,
    'OEBPS/style.css': _styleCss,
    for (final entry in entries.entries) entry.key: entry.value,
  };
}

/// A valid publication whose hrefs exercise Unicode names, percent
/// encoding, nested relative paths and an in-document fragment.
Map<String, Object> _unicodeEntries() {
  const nav = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Table of contents</title></head>
  <body>
    <nav epub:type="toc">
      <h1>Contents</h1>
      <ol>
        <li><a href="textos/cap%C3%ADtulo%20um.xhtml">Capítulo um</a></li>
        <li><a href="textos/cap%C3%ADtulo%20um.xhtml#nota-1">Nota</a></li>
      </ol>
    </nav>
  </body>
</html>
''';
  const chapter = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Capítulo um</title></head>
  <body><h1>Capítulo um</h1><p id="nota-1">Uma nota de rodapé.</p></body>
</html>
''';
  return {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': _containerXml,
    'OEBPS/content.opf': _epub3Opf(
      manifest:
          '''    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="textos/cap%C3%ADtulo%20um.xhtml" media-type="application/xhtml+xml"/>
''',
      spine: '    <itemref idref="ch1"/>\n',
    ),
    'OEBPS/nav.xhtml': nav,
    'OEBPS/textos/capítulo um.xhtml': chapter,
  };
}

String _sha256(final List<int> bytes) => sha256.convert(bytes).toString();

Uint8List _zip(final Map<String, Object> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = Uint8List.fromList(
      entry.value is String ? utf8.encode(entry.value as String) : entry.value as List<int>,
    );
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes)..lastModTime = _fixedTime);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}
