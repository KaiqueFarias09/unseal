// Fixture loading for the unseal benchmarks.
//
// Reuses the public-domain books under test/resources. Fixtures are
// loaded once and cached; derived samples (largest HTML chapter, image
// bytes) are extracted lazily from the parsed fixtures.

import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

import 'benchmark_harness.dart' show formatBytes;

/// A test book loaded into memory for benchmarking.
final class BookFixture {
  /// Creates a fixture from its [name], [path] and [bytes].
  const BookFixture({
    required this.name,
    required this.path,
    required this.bytes,
    this.displayName,
    this.fixtureId = '',
  });

  /// The fixture name, relative to `test/resources`.
  final String name;

  /// Absolute path of the fixture file, for path-based APIs.
  final String path;

  /// The raw file bytes.
  final Uint8List bytes;

  /// Short name used in benchmark labels for wordy file names.
  final String? displayName;

  /// Stable id recorded in the JSON report; corpus-manifest id when the
  /// fixture is listed there, otherwise empty.
  final String fixtureId;

  /// Short display label, e.g. `vertical-writing-ja.epub (261 KB)`.
  String get label {
    return '${displayName ?? name.split('/').last} '
        '(${formatBytes(bytes.length)})';
  }

  /// The fixture name without size, for labels that add their own
  /// context.
  String get shortLabel => displayName ?? name.split('/').last;
}

final Map<String, BookFixture> _cache = <String, BookFixture>{};

/// Loads `test/resources/[relativePath]`, caching by path.
BookFixture loadFixture(
  final String relativePath, {
  final String? displayName,
  final String fixtureId = '',
}) {
  return _cache.putIfAbsent(relativePath, () {
    final file = File(_locate('test/resources/$relativePath'));
    if (!file.existsSync()) {
      throw StateError(
        'Missing benchmark fixture ${file.path}. '
        'Run the benchmarks from the repository root.',
      );
    }

    return BookFixture(
      name: relativePath,
      path: file.path,
      bytes: file.readAsBytesSync(),
      displayName: displayName,
      fixtureId: fixtureId,
    );
  });
}

String _locate(final String relative) {
  var directory = Directory.current;
  for (var i = 0; i < 4; i++) {
    final candidate = File('${directory.path}/$relative');
    if (candidate.existsSync()) return candidate.path;

    final parent = directory.parent;
    if (parent.path == directory.path) break;

    directory = parent;
  }

  return relative;
}

/// Fixtures whose full parse / metadata read run on the synchronous
/// dispatcher ([Unseal.parse] / [Unseal.readMetadataSync]).
///
/// CB7 and CBC are async-only at the public API (7-Zip work runs on an
/// isolate) — they are measured through [asyncParsingFixtures] instead,
/// so every format still gets both a parse and a metadata scenario.
/// Detection rows iterate the full [parsingFixtures] ∪
/// [asyncParsingFixtures] set.
List<BookFixture> get parsingFixtures => <BookFixture>[
  ..._classicParsingFixtures,
  ...formatMatrixFixtures.where(_syncParseable),
];

/// Whether the synchronous dispatcher supports the fixture's format.
bool _syncParseable(final BookFixture fixture) => fixture != cb7Matrix && fixture != cbcMatrix;

/// Fixtures measured through the async entry points
/// ([Unseal.read] / [Unseal.readMetadata]):
/// the 7-Zip-backed formats.
List<BookFixture> get asyncParsingFixtures => <BookFixture>[cb7Matrix, cbcMatrix];

List<BookFixture> get _classicParsingFixtures => <BookFixture>[
  epubSmall,
  epubAlice,
  epubLinearAlgebra,
  epubFixedLayout,
  mobi6Alice,
  mobi8Alice,
  mobiJointAlice,
  fb2Alice,
  comicSample,
];

/// A small vertical-writing EPUB.
BookFixture get epubSmall => loadFixture('books/epub/vertical-writing-ja.epub');

/// Alice in Wonderland as an EPUB (868 KB).
BookFixture get epubAlice {
  return loadFixture('epub/Alices Adventures in Wonderland.epub', displayName: 'alice.epub');
}

/// A math textbook EPUB (1.7 MB).
BookFixture get epubLinearAlgebra => loadFixture('epub/linear-algebra.epub');

/// A focused fixed-layout EPUB.
BookFixture get epubFixedLayout => loadFixture('books/epub/page-blanche.epub');

/// Alice in Wonderland as MOBI 6 (3.2 MB).
BookFixture get mobi6Alice => loadFixture('mobi/alice-old.mobi');

/// Alice in Wonderland as KF8 / AZW3 (948 KB).
BookFixture get mobi8Alice => loadFixture('mobi/alice-kf8.azw3');

/// Alice in Wonderland as a joint MOBI 6 + KF8 file (3.6 MB).
BookFixture get mobiJointAlice => loadFixture('mobi/alice-joint.mobi');

/// Alice in Wonderland as FictionBook 2.0 (3.2 MB).
BookFixture get fb2Alice => loadFixture('fb2/alice.fb2');

/// A small CBZ comic (4 KB).
BookFixture get comicSample => loadFixture('comic/sample.cbz');

/// The EPUB carrying a `metadata.opf` sidecar.
BookFixture get epubWithSidecar => loadFixture('sidecar/alice.epub');

/// One fixture per non-EPUB [BookFormat], following the public corpus
/// manifest (`test/resources/books/manifest.json`, `format_fixtures`):
/// together with the EPUB fixtures above, the full 16-format matrix.
///
/// Every entry keeps the manifest's fixture id so benchmark reports
/// join against the manifest, and all files are deterministic
/// checked-in fixtures (public-domain or generated) — the tracked
/// benchmark never depends on a private corpus.
/// The 7-Zip comic archive fixture (FORMAT-CB7); cached, so instance
/// equality with [formatMatrixFixtures] entries holds.
BookFixture get cb7Matrix => loadFixture(
  'books/comic/synthetic-pages.cb7',
  displayName: 'synthetic-pages.cb7',
  fixtureId: 'FORMAT-CB7',
);

/// The comic-collection fixture (FORMAT-CBC); cached, so instance
/// equality with [formatMatrixFixtures] entries holds.
BookFixture get cbcMatrix => loadFixture(
  'books/comic/synthetic-collection.cbc',
  displayName: 'synthetic-collection.cbc',
  fixtureId: 'FORMAT-CBC',
);

final List<BookFixture> formatMatrixFixtures = <BookFixture>[
  loadFixture(
    'books/mobi/alice-old-pg.mobi',
    displayName: 'alice-old-pg.mobi',
    fixtureId: 'FORMAT-MOBI6',
  ),
  loadFixture(
    'books/mobi/alice-kf8-pg.azw3',
    displayName: 'alice-kf8-pg.azw3',
    fixtureId: 'FORMAT-AZW3',
  ),
  loadFixture(
    'books/fb2/synthetic-multilingual.fb2',
    displayName: 'synthetic-multilingual.fb2',
    fixtureId: 'FORMAT-FB2',
  ),
  loadFixture(
    'books/comic/synthetic-pages.cbz',
    displayName: 'synthetic-pages.cbz',
    fixtureId: 'FORMAT-CBZ',
  ),
  loadFixture(
    'books/comic/synthetic-stored-pages.cbr',
    displayName: 'synthetic-stored-pages.cbr',
    fixtureId: 'FORMAT-CBR',
  ),
  loadFixture(
    'books/pdf/dickens-sample.pdf',
    displayName: 'dickens-sample.pdf',
    fixtureId: 'FORMAT-PDF',
  ),
  loadFixture('books/txt/synthetic.txt', displayName: 'synthetic.txt', fixtureId: 'FORMAT-TXT'),
  loadFixture('books/txt/synthetic.txtz', displayName: 'synthetic.txtz', fixtureId: 'FORMAT-TXTZ'),
  loadFixture('books/html/synthetic.html', displayName: 'synthetic.html', fixtureId: 'FORMAT-HTML'),
  loadFixture(
    'books/html/synthetic.htmlz',
    displayName: 'synthetic.htmlz',
    fixtureId: 'FORMAT-HTMLZ',
  ),
  loadFixture('books/docx/synthetic.docx', displayName: 'synthetic.docx', fixtureId: 'FORMAT-DOCX'),
  loadFixture('books/mobi/synthetic.azw4', displayName: 'synthetic.azw4', fixtureId: 'FORMAT-AZW4'),
  cb7Matrix,
  cbcMatrix,
  loadFixture('books/odt/synthetic.odt', displayName: 'synthetic.odt', fixtureId: 'FORMAT-ODT'),
];

bool _derivedReady = false;
TextFile? _largestHtml;
String? _plainText;
final Map<ImageType, Uint8List> _images = <ImageType, Uint8List>{};

/// The largest HTML chapter among the EPUB fixtures, for text
/// benchmarks. `null` when no fixture carries HTML.
TextFile? get largestHtmlFile {
  _ensureDerived();

  return _largestHtml;
}

/// The plain text of [largestHtmlFile], computed once.
String? get plainTextSample {
  _ensureDerived();

  return _plainText;
}

/// A cached image of [type] extracted from the fixtures, or `null`.
Uint8List? imageSample(final ImageType type) {
  _ensureDerived();

  return _images[type];
}

void _ensureDerived() {
  if (_derivedReady) return;

  _derivedReady = true;
  final books = <Book>[Unseal.parse(epubAlice.bytes), Unseal.parse(comicSample.bytes)];
  for (final book in books) {
    final images = book is ComicBook ? book.pages : book.files.images;
    for (final image in images) {
      final type = sniffImageType(image.content);
      if (type != null && !_images.containsKey(type)) {
        _images[type] = image.content;
      }
    }
    for (final file in book.files.html) {
      if (_largestHtml == null || file.content.length > _largestHtml!.content.length) {
        _largestHtml = file;
      }
    }
  }

  final html = _largestHtml;
  if (html != null) {
    _plainText = extractPlainText(html.content);
  }
}
