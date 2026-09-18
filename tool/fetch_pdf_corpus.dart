import 'dart:io';

/// Downloads the Project Gutenberg PDF corpus fixtures into
/// `test/resources/pdf/gutenberg/`, the corpus `pdf_corpus_test.dart` runs
/// against. Safe to re-run: books already on disk (valid `%PDF` header) are
/// skipped.
///
/// For every id in [_corpusIds] the script first tries the PG-native PDF
/// editions (`files/<id>/<id>-pdf.pdf`, then `cache/epub/<id>/pg<id>-pdf.pdf`)
/// and stores one as `pg<id>.pdf`. Gutenberg has retired those editions, so
/// the fallback applies: the UTF-8 plain text is downloaded and rendered into
/// `pg<id>-generated.pdf` with macOS `cupsfilter` — the `-generated` suffix
/// marks that origin. Size guards: no single book above [_maxFileBytes], the
/// whole corpus above [_maxCorpusBytes].
void main() async {
  final corpusDir = Directory('test/resources/pdf/gutenberg');
  await corpusDir.create(recursive: true);

  var totalBytes = _corpusBytes(corpusDir);
  var failures = 0;
  for (final id in _corpusIds) {
    final existing = _existingBook(corpusDir, id);
    if (existing != null) {
      stdout.writeln('pg$id: ${_name(existing)} already present, skipping.');
      continue;
    }
    if (totalBytes >= _maxCorpusBytes) {
      stderr.writeln('pg$id: corpus cap of $_maxCorpusBytes bytes reached.');
      failures++;

      break;
    }

    final book = await _downloadNative(corpusDir, id) ?? await _generateFromText(corpusDir, id);
    if (book == null) {
      stderr.writeln('pg$id: every source failed; missing from the corpus.');
      failures++;

      continue;
    }

    final size = book.lengthSync();
    if (size > _maxFileBytes || totalBytes + size > _maxCorpusBytes) {
      book.deleteSync();
      stderr.writeln('pg$id: ${_name(book)} is $size bytes, over the size cap; skipped.');
      failures++;

      continue;
    }

    totalBytes += size;
    stdout.writeln('pg$id: ${_name(book)} downloaded ($size bytes).');
  }

  if (failures > 0) {
    stderr.writeln('$failures book(s) could not be fetched.');
    exitCode = 1;
  }
}

/// The Gutenberg ebook ids in the corpus.
const _corpusIds = <int>[11, 1342, 84, 2701, 1661, 5200, 98, 174];

/// Size guard per book (~1.5 MB) and for the whole corpus.
const _maxFileBytes = 1500 * 1000;
const _maxCorpusBytes = 10 * 1000 * 1000;

/// PG-native PDF editions, preferred when Gutenberg still publishes them.
const _nativeUrls = <String>[
  'https://www.gutenberg.org/files/{id}/{id}-pdf.pdf',
  'https://www.gutenberg.org/cache/epub/{id}/pg{id}-pdf.pdf',
];

/// UTF-8 plain texts, the fallback rendered into PDF by `cupsfilter`.
const _textUrls = <String>[
  'https://www.gutenberg.org/cache/epub/{id}/pg{id}.txt.utf-8',
  'https://www.gutenberg.org/files/{id}/{id}-0.txt',
];

/// Downloads a PG-native PDF as `pg<id>.pdf`, or null when unavailable.
Future<File?> _downloadNative(final Directory corpusDir, final int id) async {
  final target = File('${corpusDir.path}/pg$id.pdf');
  for (final pattern in _nativeUrls) {
    if (!await _curl(pattern.replaceAll('{id}', '$id'), target)) continue;
    if (_hasPdfHeader(target)) return target;

    target.deleteSync();
  }

  return null;
}

/// Renders `pg<id>-generated.pdf` from the UTF-8 text via `cupsfilter`.
Future<File?> _generateFromText(final Directory corpusDir, final int id) async {
  final text = File('${Directory.systemTemp.path}/pg$id.txt');
  for (final pattern in _textUrls) {
    if (!await _curl(pattern.replaceAll('{id}', '$id'), text)) continue;

    final result = await Process.run('cupsfilter', <String>[text.path], stdoutEncoding: null);
    text.deleteSync();
    if (result.exitCode != 0) continue;

    final book = File('${corpusDir.path}/pg$id-generated.pdf');
    await book.writeAsBytes(result.stdout as List<int>);
    if (_hasPdfHeader(book)) return book;

    book.deleteSync();
  }
  text.deleteSync();

  return null;
}

/// Fetches [url] into [target] with curl, following redirects.
Future<bool> _curl(final String url, final File target) async {
  final result = await Process.run('curl', <String>[
    '-sfL',
    '--max-time',
    '120',
    '-o',
    target.path,
    url,
  ]);

  return result.exitCode == 0 && target.existsSync();
}

/// The corpus book for [id] already on disk, or null when missing or broken.
File? _existingBook(final Directory corpusDir, final int id) {
  for (final name in <String>['pg$id.pdf', 'pg$id-generated.pdf']) {
    final candidate = File('${corpusDir.path}/$name');
    if (candidate.existsSync() && _hasPdfHeader(candidate)) return candidate;
  }

  return null;
}

/// Total bytes of the PDFs already in [corpusDir].
int _corpusBytes(final Directory corpusDir) {
  return corpusDir
      .listSync()
      .whereType<File>()
      .where((final file) => file.path.endsWith('.pdf'))
      .fold(0, (final sum, final file) => sum + file.lengthSync());
}

/// Whether [file] starts with the `%PDF` magic.
bool _hasPdfHeader(final File file) {
  if (file.lengthSync() < 4) return false;

  final head = file.readAsBytesSync().sublist(0, 4);

  return head[0] == 0x25 && head[1] == 0x50 && head[2] == 0x44 && head[3] == 0x46;
}

/// The base name of [file].
String _name(final File file) => file.uri.pathSegments.last;
