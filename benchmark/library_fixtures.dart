// Real-corpus fixtures loaded from the user's configured library.
//
// The library root comes from the `UNSEAL_BENCH_LIBRARY` environment
// variable (for example, `/Users/example/Library`). Book files
// stay outside the repository and load by path at runtime; groups
// built on this loader skip gracefully — with a printed note — when
// the variable is unset, the directory is missing, or a named book is
// not found, keeping the suite runnable anywhere.

import 'dart:io';
import 'dart:typed_data';

import 'benchmark_harness.dart' show formatBytes;
import 'json_report.dart' show jsonSuppression;

/// The supported real-book file extensions.
const Set<String> _bookExtensions = <String>{'.epub', '.mobi', '.azw3', '.fb2'};

/// A real book from the configured library, referenced by path.
///
/// Bytes load on demand through [read] so a whole-library scan never
/// holds every book in memory at once.
final class LibraryBook {
  /// Creates a library book reference.
  const LibraryBook({required this.name, required this.path, required this.size});

  /// The book file name, e.g. `Lord of the Rings - Tolkien.epub`.
  final String name;

  /// The absolute file path inside the library.
  final String path;

  /// The file size in bytes.
  final int size;

  /// Reads the full book bytes.
  Uint8List read() => File(path).readAsBytesSync();

  /// Short display label, e.g. `Lord of the Rings (7.1 MB)`.
  String get label => '$name (${formatBytes(size)})';
}

final String? _libraryRoot = _resolveRoot();
List<LibraryBook>? _books;

String? _resolveRoot() {
  final value = Platform.environment['UNSEAL_BENCH_LIBRARY'];
  if (value == null || !Directory(value).existsSync()) return null;

  return value;
}

/// The configured library root, or `null` when `UNSEAL_BENCH_LIBRARY`
/// is unset or does not point at a directory.
String? get libraryRoot => _libraryRoot;

/// Prints the standard skip note for groups that need the real corpus.
void skipLibraryGroup(final String groupLabel) {
  if (jsonSuppression) {
    return;
  }
  stdout.writeln(
    '[$groupLabel] skipped — set UNSEAL_BENCH_LIBRARY to a Calibre '
    'library root to enable the real-corpus benchmarks.',
  );
}

/// Every supported book in the library, cached. Empty when no library
/// root is configured.
List<LibraryBook> get libraryBooks {
  final root = _libraryRoot;
  if (root == null) return const <LibraryBook>[];

  return _books ??=
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((final file) => _bookExtensions.contains(_extension(file.path)))
          .map((final file) {
            final size = file.lengthSync();

            return LibraryBook(name: _fileName(file.path), path: file.path, size: size);
          })
          .toList()
        ..sort((final a, final b) => a.name.compareTo(b.name));
}

/// Finds a library book by exact file [name], or `null` when no
/// library root is configured or no book matches.
LibraryBook? findLibraryBook(final String name) {
  for (final book in libraryBooks) {
    if (book.name == name) return book;
  }

  return null;
}

String _extension(final String path) {
  final dot = path.lastIndexOf('.');

  return dot < 0 ? '' : path.substring(dot).toLowerCase();
}

String _fileName(final String path) {
  final slash = path.lastIndexOf(Platform.pathSeparator);

  return slash < 0 ? path : path.substring(slash + 1);
}
