// Fixture loading for the eLivre benchmarks.
//
// Reuses the public-domain books under test/resources. Fixtures are
// loaded once and cached; derived samples (largest HTML chapter, image
// bytes) are extracted lazily from the parsed fixtures.

import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart' show formatBytes;

/// A test book loaded into memory for benchmarking.
final class BookFixture {
  /// Creates a fixture from its [name], [path] and [bytes].
  const BookFixture({
    required this.name,
    required this.path,
    required this.bytes,
    this.displayName,
  });

  /// The fixture name, relative to `test/resources`.
  final String name;

  /// Absolute path of the fixture file, for path-based APIs.
  final String path;

  /// The raw file bytes.
  final Uint8List bytes;

  /// Short name used in benchmark labels for wordy file names.
  final String? displayName;

  /// Short display label, e.g. `sample1.epub (188 KB)`.
  String get label =>
      '${displayName ?? name.split('/').last} '
      '(${formatBytes(bytes.length)})';

  /// The fixture name without size, for labels that add their own
  /// context.
  String get shortLabel => displayName ?? name.split('/').last;
}

final Map<String, BookFixture> _cache = <String, BookFixture>{};

/// Loads `test/resources/[relativePath]`, caching by path.
BookFixture loadFixture(
  final String relativePath, {
  final String? displayName,
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
    );
  });
}

String _locate(final String relative) {
  var directory = Directory.current;
  for (var i = 0; i < 4; i++) {
    final candidate = File('${directory.path}/$relative');
    if (candidate.existsSync()) {
      return candidate.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      break;
    }
    directory = parent;
  }
  return relative;
}

/// All fixtures exercised by the parse / metadata-read benchmarks.
List<BookFixture> get parsingFixtures => <BookFixture>[
      epubSmall,
      epubAlice,
      epubLinearAlgebra,
      epubFamousPaintings,
      mobi6Alice,
      mobi8Alice,
      mobiJointAlice,
      fb2Alice,
      comicSample,
    ];

/// A small EPUB (188 KB).
BookFixture get epubSmall => loadFixture('epub/sample1.epub');

/// Alice in Wonderland as an EPUB (868 KB).
BookFixture get epubAlice => loadFixture(
      'epub/Alices Adventures in Wonderland.epub',
      displayName: 'alice.epub',
    );

/// A math textbook EPUB (1.7 MB).
BookFixture get epubLinearAlgebra => loadFixture('epub/linear-algebra.epub');

/// An image-heavy art book EPUB (6.4 MB).
BookFixture get epubFamousPaintings => loadFixture('epub/famouspaintings.epub');

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

/// The EPUB carrying a Calibre `metadata.opf` sidecar.
BookFixture get epubWithSidecar => loadFixture('sidecar/sample1.epub');

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
  if (_derivedReady) {
    return;
  }
  _derivedReady = true;
  final books = <Book>[
    EBook.parseBook(epubAlice.bytes),
    EBook.parseBook(comicSample.bytes),
  ];
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
