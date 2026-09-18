/// Access to the tracked fuzz corpus at `test/resources/fuzz`.
///
/// The corpus is owned by a parallel tooling stream and may be absent
/// on this branch. Every consumer must stay tolerant: when the
/// directory does not exist the helpers return an empty list and the
/// suites skip their corpus-driven tests cleanly, so the fuzz front
/// stays independently green.
library;

import 'dart:io';

/// Default per-file cap for corpus consumption (4 MiB).
const int defaultCorpusMaxFileBytes = 4 << 20;

/// Returns the corpus root directory when it exists, null otherwise.
Directory? fuzzCorpusRoot() {
  final directory = Directory('test/resources/fuzz');
  if (!directory.existsSync()) return null;

  return directory;
}

/// Whether the tracked corpus is available.
bool get fuzzCorpusPresent => fuzzCorpusRoot() != null;

/// Lists corpus files deterministically (sorted by path), capped by
/// [maxBytes] per file and [limit] in total.
List<File> fuzzCorpusFiles({final int limit = 64, final int maxBytes = defaultCorpusMaxFileBytes}) {
  final root = fuzzCorpusRoot();
  if (root == null) return const <File>[];

  final files =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((final file) => file.lengthSync() <= maxBytes)
          .toList()
        ..sort((final a, final b) => a.path.compareTo(b.path));

  return files.take(limit).toList();
}

/// A stable, privacy-free fixture id for a corpus file (relative path).
String fuzzCorpusFixtureId(final File file, final Directory root) =>
    'corpus/${file.path.substring(root.path.length + 1).replaceAll('\\', '/')}';
