// Tracked-fixture corpus inventory with a fast parse smoke check.
//
// Enumerates every TRACKED file under test/resources, classifies it by
// container/format, hashes it, cross-checks the books manifest, parses
// book-shaped fixtures in killable worker isolates (with a deadline),
// and emits:
//
//  * a deterministic TRACKED manifest (default:
//    test/resources/fuzz/corpus-manifest.json) — static facts only:
//    path, format family, size, sha256, structural landmark count;
//  * a LIVE validation report under the artifacts folder (default
//    ../../../artifacts/goal3/corpus, override with --out-report) —
//    parse status and durations, which drift as parsers evolve.
//
// Usage:
//
//     dart run tool/fuzz_corpus_inventory.dart \
//       [--timeout-seconds=30] [--skip-parse] \
//       [--out-manifest=<file>] [--check-manifest] [--out-report=<file>]
//
// Exit codes: 0 clean, 1 validation failures (parse failures, manifest
// drift, hash mismatches), 64 usage.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:e_livre/e_livre.dart';

import 'fuzz/parse_probe.dart';
import 'fuzz/structure_offsets.dart';

const String _defaultManifestPath = 'test/resources/fuzz/corpus-manifest.json';
const String _resourcesRoot = 'test/resources';
const String _booksManifestPath = 'test/resources/books/manifest.json';

Future<void> main(final List<String> arguments) async {
  final options = _parseOptions(arguments);
  final tracked = _trackedResourceFiles();
  if (tracked.isEmpty) {
    stderr.writeln(
      'inventory: no tracked files found under $_resourcesRoot (git ls-files empty?).',
    );
    exitCode = 64;
    return;
  }

  final booksManifest = _loadBooksManifest();
  final entries = <Map<String, Object?>>[];
  final validation = <Map<String, Object?>>[];
  final formats = <String, int>{};
  var totalBytes = 0;
  var failures = 0;

  for (final relativePath in tracked) {
    final bytes = await File(relativePath).readAsBytes();
    final family = _familyFor(relativePath, bytes);
    formats[family] = (formats[family] ?? 0) + 1;
    totalBytes += bytes.length;

    final scan = StructureScan.scan(bytes);
    entries.add({
      'path': relativePath,
      'format': family,
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'container': scan.container.name,
      'landmarks': scan.offsets.length,
      if (relativePath.startsWith('$_resourcesRoot/fuzz/generated/')) 'generated': true,
      if (booksManifest.containsKey(relativePath)) 'bookId': booksManifest[relativePath]!['id'],
    });

    // --- live checks (artifacts only) ---
    final problems = <String>[];
    final bookRef = booksManifest[relativePath];
    if (bookRef != null) {
      if (bookRef['bytes'] != bytes.length) {
        problems.add('books-manifest byte mismatch');
      }
      if (bookRef['sha256'] != sha256.convert(bytes).toString()) {
        problems.add('books-manifest sha256 mismatch');
      }
    }

    if (!options.skipParse && _isBookShaped(family)) {
      // CB7/CBC parse asynchronously, so the probe uses the async facade.
      final result = await probeParse(
        bytes,
        (final data) async => BookReader.openFromBytes(data),
        timeout: Duration(seconds: options.timeoutSeconds),
      );
      // A graceful typed rejection (encrypted PDF, unsupported shape) is
      // the library behaving well: not a validation failure.
      final ok =
          result.status == ProbeStatus.ok ||
          (result.status == ProbeStatus.threw && result.graceful);
      if (!ok) {
        failures++;
        problems.add('parse ${result.signature}');
      }
      validation.add({
        'path': relativePath,
        'status': result.status.name,
        'detail': result.detail,
        'durationMs': result.durationMs,
        'problems': problems,
      });
    } else {
      if (problems.isNotEmpty) {
        failures++;
      }
      validation.add({
        'path': relativePath,
        'status': options.skipParse ? 'skipped' : 'resource',
        'detail': '',
        'durationMs': 0,
        'problems': problems,
      });
    }
  }

  entries.sort((final a, final b) => (a['path'] as String).compareTo(b['path'] as String));

  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'fuzz-corpus-manifest',
    'root': _resourcesRoot,
    'files': entries,
    'counts': {'total': entries.length, 'totalBytes': totalBytes, 'byFormat': formats},
  };

  if (options.checkManifest) {
    final committed = File(options.manifestPath);
    if (!committed.existsSync()) {
      stderr.writeln('manifest check FAILED: ${options.manifestPath} does not exist.');
      exitCode = 1;
      return;
    }
    final expected = const JsonEncoder.withIndent('  ').convert(manifest);
    final actual = const JsonEncoder.withIndent(
      '  ',
    ).convert(jsonDecode(committed.readAsStringSync()));
    if (expected != actual) {
      stderr.writeln(
        'manifest check FAILED: ${options.manifestPath} is stale; '
        'run dart run tool/fuzz_corpus_inventory.dart to refresh it.',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('manifest check OK: ${entries.length} tracked files.');
  } else {
    File(
      options.manifestPath,
    ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n', flush: true);
    stdout.writeln(
      'manifest written: ${options.manifestPath} (${entries.length} files, '
      '${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
    );
  }

  final reportPath = options.reportPath;
  if (reportPath != null) {
    final report = <String, Object?>{
      'schemaVersion': 1,
      'kind': 'fuzz-corpus-validation',
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'timeoutSeconds': options.timeoutSeconds,
      'counts': {'total': entries.length, 'failures': failures, 'byFormat': formats},
      'items': validation,
    };
    File(reportPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n', flush: true);
    stdout.writeln('validation report written: $reportPath');
  }

  if (failures > 0) {
    stderr.writeln('inventory: $failures file(s) failed validation.');
    exitCode = 1;
  }
}

/// True when the fixture family goes through [BookReader.parseBook].
bool _isBookShaped(final String family) =>
    !const {'image', 'manifest', 'license', 'resource'}.contains(family);

/// Classifies a fixture by extension first (stable names), magic bytes second.
String _familyFor(final String path, final Uint8List bytes) {
  final extension = path.split('.').last.toLowerCase();
  const byExtension = {
    'epub': 'epub',
    'mobi': 'mobi',
    'azw3': 'azw3',
    'azw4': 'azw4',
    'pdf': 'pdf',
    'fb2': 'fb2',
    'docx': 'docx',
    'odt': 'odt',
    'txt': 'txt',
    'txtz': 'txtz',
    'html': 'html',
    'htmlz': 'htmlz',
    'cbz': 'cbz',
    'cbr': 'cbr',
    'cb7': 'cb7',
    'cbc': 'cbc',
    'png': 'image',
    'jpg': 'image',
    'jpeg': 'image',
    'gif': 'image',
    'json': 'manifest',
    'md': 'manifest',
    'opf': 'xml-sidecar',
    'xml': 'xml-sidecar',
  };
  final byExt = byExtension[extension];
  if (byExt != null) {
    return byExt;
  }
  try {
    return detectFormat(bytes).name;
  } on Object {
    return 'resource';
  }
}

/// Sorted relative paths of all git-tracked files under test/resources.
List<String> _trackedResourceFiles() {
  final result = Process.runSync('git', ['ls-files', _resourcesRoot]);
  if (result.exitCode != 0) {
    return const [];
  }
  return (result.stdout as String)
      .split('\n')
      .map((final line) => line.trim())
      .where((final line) => line.isNotEmpty)
      .where((final line) => !line.endsWith('/'))
      .toList()
    ..sort();
}

/// file path -> {id, bytes, sha256} from the curated books manifest.
Map<String, Map<String, Object?>> _loadBooksManifest() {
  final file = File(_booksManifestPath);
  if (!file.existsSync()) {
    return {};
  }
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final books = decoded['books'] as List<Object?>? ?? const [];
  return {
    for (final book in books)
      '$_resourcesRoot/books/${(book as Map<String, Object?>)['file']}': book,
  };
}

final class _Options {
  String manifestPath = _defaultManifestPath;
  String? reportPath;
  int timeoutSeconds = 30;
  bool checkManifest = false;
  bool skipParse = false;
}

_Options _parseOptions(final Iterable<String> arguments) {
  final options = _Options();
  for (final argument in arguments) {
    final value = argument.contains('=') ? argument.split('=').skip(1).join('=') : null;
    if (argument.startsWith('--out-manifest=') && value != null) {
      options.manifestPath = value;
    } else if (argument.startsWith('--out-report=') && value != null) {
      options.reportPath = value;
    } else if (argument.startsWith('--timeout-seconds=') && value != null) {
      options.timeoutSeconds = int.tryParse(value) ?? 30;
    } else if (argument == '--check-manifest') {
      options.checkManifest = true;
    } else if (argument == '--skip-parse') {
      options.skipParse = true;
    }
  }
  return options;
}
