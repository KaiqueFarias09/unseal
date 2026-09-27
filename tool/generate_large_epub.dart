// Generates large synthetic EPUB fixtures for the progressive-reading
// benchmarks. Deterministic: the same command on the same SDK writes
// byte-identical files (seed lives in large_fixture_kit.dart).
//
//     dart run tool/generate_large_epub.dart reflowable [--out=<dir>] [--verify]
//     dart run tool/generate_large_epub.dart fxl        [--out=<dir>] [--verify]
//     dart run tool/generate_large_epub.dart all        [--out=<dir>] [--verify]
//
// * reflowable  ~300 XHTML chapters of ~40 KB prose each, one CSS file,
//    20 PNG images (~768 KB each) referenced across chapters; EPUB 3
//    OPF + nav TOC with NCX fallback.
// * fxl         60 fixed-layout pages (1200x1700 viewport,
//    `layout-pre-paginated` manifest properties + rendition metadata
//    in the OPF), each embedding one ~400 KB PNG.
// * all         both of the above.
//
// `--verify` parses each generated file back through `Unseal.parse` and
// checks the structural counts before reporting the manifest. Output
// goes to `build/fixtures/` by default (git-ignored); the manifest JSON
// on stdout records path, bytes and chapter/page counts.
//
// This tool writes only inside its output directory; it never touches
// test/resources (tracked fixtures are source data).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

import 'large_fixture_kit.dart';

Future<void> main(final List<String> arguments) async {
  final targets = arguments.where((final a) => !a.startsWith('--')).toList();
  final out = _optionValue(arguments, '--out') ?? defaultFixtureDirectory;
  final verify = arguments.contains('--verify');
  if (targets.isEmpty || targets.any((final t) => !_targets.contains(t))) {
    stderr.writeln(
      'usage: dart run tool/generate_large_epub.dart <reflowable|fxl|all> '
      '[--out=<dir>] [--verify]',
    );
    exitCode = 64;
    return;
  }
  final run = targets.contains('all') ? _targets.toList() : targets;

  final manifestFiles = <Map<String, Object?>>[];
  for (final target in run) {
    switch (target) {
      case 'reflowable':
        _writeReflowable(out, verify: verify, manifestFiles: manifestFiles);
      case 'fxl':
        _writeFxl(out, verify: verify, manifestFiles: manifestFiles);
    }
  }

  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'large-fixture-manifest',
    'generator': 'tool/generate_large_epub.dart',
    'seed': fixtureSeed,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'files': manifestFiles,
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(manifest));
}

const List<String> _targets = ['reflowable', 'fxl'];

String? _optionValue(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

String _pad(final int number) => number.toString().padLeft(3, '0');

// --- reflowable ---

const int _chapterCount = 300;
const int _chapterTargetBytes = 40 * 1024;
const int _imageCount = 20;
const int _imagePixelSize = 512; // 512x512 RGB noise deflates to ~787 KB

void _writeReflowable(
  final String out, {
  required final bool verify,
  required final List<Map<String, Object?>> manifestFiles,
}) {
  final watch = Stopwatch()..start();
  final random = SplitMix64(fixtureSeed);
  final entries = <String, List<int>>{
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode(_container),
    'OEBPS/content.opf': utf8.encode(_reflowableOpf()),
    'OEBPS/nav.xhtml': utf8.encode(_navDocument(count: _chapterCount, filePrefix: _chapterFile)),
    'OEBPS/toc.ncx': utf8.encode(_ncxDocument(count: _chapterCount, filePrefix: _chapterFile)),
    'OEBPS/styles/book.css': utf8.encode(_stylesheet),
  };
  for (var index = 0; index < _imageCount; index++) {
    final image = buildNoisePng(width: _imagePixelSize, height: _imagePixelSize, random: random);
    entries['OEBPS/images/image-${_pad(index + 1)}.png'] = image;
  }
  for (var chapter = 1; chapter <= _chapterCount; chapter++) {
    final body = generateChapterBody(
      chapterNumber: chapter,
      random: random,
      minimumCharacters: _chapterTargetBytes,
    );
    entries['OEBPS/text/chapter-${_pad(chapter)}.xhtml'] = utf8.encode(
      _reflowableChapter(chapter, body: body),
    );
  }
  final bytes = buildZip(entries, firstStoredEntry: 'mimetype');
  const name = 'large-reflowable.epub';
  manifestFiles.add({
    'path': _write(out, name, bytes),
    'bytes': bytes.length,
    'chapters': _chapterCount,
    'images': _imageCount,
    'targetChapterBytes': _chapterTargetBytes,
    if (verify)
      'verification': _verifyBook('$out/$name', chapters: _chapterCount, images: _imageCount),
  });
  stdout.writeln('reflowable: $name in ${watch.elapsedMilliseconds}ms');
}

// --- fixed layout ---

const int _pageCount = 60;
const int _fxlImagePixelSize = 368; // 368x368 RGB noise deflates to ~397 KB
const int _fxlTargetImageBytes = 400 * 1024;

void _writeFxl(
  final String out, {
  required final bool verify,
  required final List<Map<String, Object?>> manifestFiles,
}) {
  final watch = Stopwatch()..start();
  final random = SplitMix64(fixtureSeed + 1);
  final entries = <String, List<int>>{
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode(_container),
    'OEBPS/content.opf': utf8.encode(_fxlOpf()),
    'OEBPS/nav.xhtml': utf8.encode(_navDocument(count: _pageCount, filePrefix: _pageFile)),
    'OEBPS/toc.ncx': utf8.encode(_ncxDocument(count: _pageCount, filePrefix: _pageFile)),
    'OEBPS/styles/fixed.css': utf8.encode(_fxlStylesheet),
  };
  for (var page = 1; page <= _pageCount; page++) {
    final image = buildNoisePng(
      width: _fxlImagePixelSize,
      height: _fxlImagePixelSize,
      random: random,
    );
    entries['OEBPS/images/page-${_pad(page)}.png'] = image;
    entries['OEBPS/text/page-${_pad(page)}.xhtml'] = utf8.encode(
      _fxlPage(page, plate: 'page-${_pad(page)}.png'),
    );
  }
  final bytes = buildZip(entries, firstStoredEntry: 'mimetype');
  const name = 'large-fxl.epub';
  manifestFiles.add({
    'path': _write(out, name, bytes),
    'bytes': bytes.length,
    'pages': _pageCount,
    'viewport': _fxlViewport,
    'targetImageBytes': _fxlTargetImageBytes,
    if (verify) 'verification': _verifyBook('$out/$name', chapters: _pageCount, images: _pageCount),
  });
  stdout.writeln('fxl: $name in ${watch.elapsedMilliseconds}ms');
}

String _write(final String out, final String name, final Uint8List bytes) {
  final path = '$out/$name';
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes, flush: true);
  return path;
}

// --- verification ---

/// Parses [path] back through the public API and returns the checks as a
/// JSON object; throws when a structural count is wrong, so `--verify`
/// fails loudly instead of shipping a broken fixture.
Map<String, Object?> _verifyBook(
  final String path, {
  required final int chapters,
  required final int images,
}) {
  final bytes = File(path).readAsBytesSync();
  final book = Unseal.parse(bytes);
  final htmlFiles = book.files.html.length;
  final imageFiles = book.files.images.length;
  final declaredBytes = book.archiveEntries.fold<int>(0, (final sum, final e) => sum + e.size);
  // files.html also carries the nav document, so only the spine-driven
  // reading order is checked exactly.
  if (htmlFiles < chapters) {
    throw StateError('verification failed: $htmlFiles html files, want >= $chapters');
  }
  if (imageFiles < images) {
    throw StateError('verification failed: $imageFiles images, want >= $images');
  }
  if (book.readingOrder.length != chapters) {
    throw StateError(
      'verification failed: reading order ${book.readingOrder.length}, want $chapters',
    );
  }
  final decodableImages = book.files.images.where((final i) => imageSize(i.content) != null).length;
  final sniffedPngs = book.files.images.where((final i) {
    return sniffImageType(i.content) == ImageType.png;
  }).length;
  if (decodableImages != imageFiles || sniffedPngs != imageFiles) {
    throw StateError('verification failed: generated PNG headers do not round-trip');
  }
  return {
    'format': book.format.name,
    'htmlFiles': htmlFiles,
    'imageFiles': imageFiles,
    'readingOrderLength': book.readingOrder.length,
    'archiveEntries': book.archiveEntries.length,
    'declaredUncompressedBytes': declaredBytes,
    'cssFiles': book.files.css.length,
    'pngHeadersOk': decodableImages,
  };
}

// --- document templates ---

const String _chapterFile = 'chapter-';
const String _pageFile = 'page-';

const String _container = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const String _stylesheet = '''
body { font-family: serif; line-height: 1.5; margin: 1em; }
h1 { font-size: 1.4em; }
p { text-indent: 1.2em; margin: 0 0 0.4em 0; }
figure { margin: 1em 0; text-align: center; }
figure img { max-width: 60%; }
''';

const String _fxlStylesheet = '''
body { margin: 0; padding: 0; }
.plate { width: 1200px; height: 1700px; object-fit: contain; }
''';

const String _fxlViewport = 'width=1200, height=1700';

String _contentManifestItems({required final int count, required final String filePrefix}) => [
  for (var index = 1; index <= count; index++)
    filePrefix == _pageFile
        ? '<item id="p$index" href="text/$filePrefix${_pad(index)}.xhtml" '
              'media-type="application/xhtml+xml" properties="layout-pre-paginated"/>'
        : '<item id="c$index" href="text/$filePrefix${_pad(index)}.xhtml" '
              'media-type="application/xhtml+xml"/>',
].join('\n    ');

String _imageManifestItems({
  required final int count,
  required final String hrefPrefix,
  required final String idPrefix,
}) => [
  for (var index = 1; index <= count; index++)
    '<item id="$idPrefix-$index" href="images/$hrefPrefix-${_pad(index)}.png" '
        'media-type="image/png"/>',
].join('\n    ');

String _navList({required final int count, required final String filePrefix}) => [
  for (var index = 1; index <= count; index++)
    '<li><a href="text/$filePrefix${_pad(index)}.xhtml">'
        '${filePrefix == _chapterFile ? 'Chapter' : 'Page'} $index</a></li>',
].join('\n      ');

String _navPoints({required final int count, required final String filePrefix}) => [
  for (var index = 1; index <= count; index++)
    '<navPoint id="np$index" playOrder="$index"><navLabel><text>'
        '${filePrefix == _chapterFile ? 'Chapter' : 'Page'} $index</text></navLabel>'
        '<content src="text/$filePrefix${_pad(index)}.xhtml"/></navPoint>',
].join('\n      ');

String _spineItemrefs({required final int count, required final String idPrefix}) =>
    [for (var index = 1; index <= count; index++) '<itemref idref="$idPrefix$index"/>'].join('\n');

String _reflowableOpf() =>
    '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="en">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:unseal-bench-large-reflowable</dc:identifier>
    <dc:title>Large Reflowable Benchmark Book</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>unseal bench tools</dc:creator>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="styles/book.css" media-type="text/css"/>
    ${_contentManifestItems(count: _chapterCount, filePrefix: _chapterFile)}
    ${_imageManifestItems(count: _imageCount, hrefPrefix: 'image', idPrefix: 'img')}
  </manifest>
  <spine toc="ncx">
    ${_spineItemrefs(count: _chapterCount, idPrefix: 'c')}
  </spine>
</package>
''';

String _fxlOpf() =>
    '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="en">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:unseal-bench-large-fxl</dc:identifier>
    <dc:title>Large Fixed-Layout Benchmark Book</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>unseal bench tools</dc:creator>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="rendition:orientation">portrait</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="styles/fixed.css" media-type="text/css"/>
    ${_contentManifestItems(count: _pageCount, filePrefix: _pageFile)}
    ${_imageManifestItems(count: _pageCount, hrefPrefix: 'page', idPrefix: 'plate')}
  </manifest>
  <spine page-progression-direction="ltr" toc="ncx">
    ${_spineItemrefs(count: _pageCount, idPrefix: 'p')}
  </spine>
</package>
''';

String _navDocument({required final int count, required final String filePrefix}) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Navigation</title></head>
<body>
  <nav epub:type="toc"><ol>
      ${_navList(count: count, filePrefix: filePrefix)}
  </ol></nav>
  <nav epub:type="landmarks" hidden="hidden"><ol>
      <li><a epub:type="bodymatter" href="text/$filePrefix${_pad(1)}.xhtml">Start of content</a></li>
  </ol></nav>
</body>
</html>
''';

String _ncxDocument({required final int count, required final String filePrefix}) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:unseal-bench-large-book"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>Large Benchmark Book</text></docTitle>
  <navMap>
      ${_navPoints(count: count, filePrefix: filePrefix)}
  </navMap>
</ncx>
''';

String _reflowableChapter(final int number, {required final String body}) {
  // Spread the twenty plates over the spine; every seventh chapter
  // carries a second figure so a few chapters hold two images.
  final figures = StringBuffer();
  final primary = number % _imageCount;
  figures.write(
    '<figure><img src="../images/image-${_pad(primary + 1)}.png" '
    'alt="Plate ${primary + 1}"/></figure>\n',
  );
  if (number % 7 == 0) {
    final secondary = (number * 3 + 5) % _imageCount;
    figures.write(
      '<figure><img src="../images/image-${_pad(secondary + 1)}.png" '
      'alt="Plate ${secondary + 1}"/></figure>\n',
    );
  }
  return '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
<head>
  <title>Chapter $number</title>
  <link rel="stylesheet" type="text/css" href="../styles/book.css"/>
</head>
<body>
$figures
$body</body>
</html>
''';
}

String _fxlPage(final int number, {required final String plate}) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
<head>
  <title>Page $number</title>
  <meta name="viewport" content="$_fxlViewport"/>
  <link rel="stylesheet" type="text/css" href="../styles/fixed.css"/>
</head>
<body>
  <img class="plate" src="../images/$plate" alt="Fixed plate $number"/>
</body>
</html>
''';
