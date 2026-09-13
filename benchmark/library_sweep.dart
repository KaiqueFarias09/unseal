// Robustness sweep and stratified sample benchmarks over a private
// Calibre library, run entirely READ-ONLY.
//
// The library root is supplied at run time — `--library=<path>`, or the
// `ELIVRE_CALIBRE_LIBRARY` / `ELIVRE_BENCH_LIBRARY` environment
// variables — and is never written to. Every output record anonymizes
// the book to a sha256 prefix of its library-relative path; file
// paths, titles, authors and file names never reach any output.
//
// Modes:
//
//     dart run benchmark/library_sweep.dart inventory \
//       --library=<root> --out=<inventory.json>
//
//     dart run benchmark/library_sweep.dart sweep \
//       --library=<root> --checkpoint=<sweep-checkpoint.json> \
//       [--out=<sweep.json>] [--timeout-seconds=120] [--concurrency=2]
//
//     dart run benchmark/library_sweep.dart sample \
//       --library=<root> --out=<sample.json> [--iterations=5]
//
// * inventory  one pass listing every file (extension + size) plus a
//   read-only parse of metadata.db's book count.
// * sweep      robustness pass over EVERY file through the isolate
//   reader with a per-book timeout; resumable via the checkpoint file
//   (completed items are kept, only pending items re-run). Items are
//   classified: ok / failed / timeout / unsupported (DRM-protected,
//   encrypted and unrecognized files are unsupported-capability, not
//   parser crashes).
// * sample     repeated timing over a stratified per-format sample
//   (smallest / median / largest per format), emitted as
//   schemaVersion-1 benchmark contract records.
//
// This tool intentionally never references a concrete library path:
// point it at any Calibre library.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:e_livre/e_livre.dart';

import 'json_report.dart' as contract;

/// Readable status of one swept item.
enum SweepStatus { ok, failed, timeout, unsupported }

Future<void> main(final List<String> arguments) async {
  if (arguments.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }
  final mode = arguments.first;
  final options = _parseOptions(arguments.skip(1));
  final root = _resolveRoot(options);
  if (root == null) {
    stderr.writeln(
      'No library root: pass --library=<path> or set '
      'ELIVRE_CALIBRE_LIBRARY / ELIVRE_BENCH_LIBRARY.',
    );
    exitCode = 64;
    return;
  }

  switch (mode) {
    case 'inventory':
      await _runInventory(root, options);
    case 'sweep':
      await _runSweep(root, options);
    case 'sample':
      await _runSample(root, options);
    default:
      stderr.writeln('Unknown mode: $mode');
      _usage();
      exitCode = 64;
  }
}

void _usage() {
  stderr.writeln(
    'usage: dart run benchmark/library_sweep.dart <inventory|sweep|sample> '
    '[--library=<root>] [--out=<file>] [--checkpoint=<file>] '
    '[--timeout-seconds=<n>] [--concurrency=<n>] [--iterations=<n>]',
  );
}

// --- options ---

final class _Options {
  String? library;
  String? out;
  String? checkpoint;
  int timeoutSeconds = 120;
  int concurrency = 2;
  int iterations = 5;
}

_Options _parseOptions(final Iterable<String> arguments) {
  final options = _Options();
  for (final argument in arguments) {
    final value = argument.contains('=') ? argument.split('=').skip(1).join('=') : null;
    if (argument.startsWith('--library=') && value != null) {
      options.library = value;
    } else if (argument.startsWith('--out=') && value != null) {
      options.out = value;
    } else if (argument.startsWith('--checkpoint=') && value != null) {
      options.checkpoint = value;
    } else if (argument.startsWith('--timeout-seconds=') && value != null) {
      options.timeoutSeconds = int.tryParse(value) ?? 120;
    } else if (argument.startsWith('--concurrency=') && value != null) {
      options.concurrency = (int.tryParse(value) ?? 2).clamp(1, 8);
    } else if (argument.startsWith('--iterations=') && value != null) {
      options.iterations = int.tryParse(value) ?? 5;
    }
  }
  return options;
}

String? _resolveRoot(final _Options options) {
  final candidate =
      options.library ??
      Platform.environment['ELIVRE_CALIBRE_LIBRARY'] ??
      Platform.environment['ELIVRE_BENCH_LIBRARY'];
  if (candidate == null) {
    return null;
  }
  return Directory(candidate).existsSync() ? candidate : null;
}

// --- library enumeration ---

/// One file of the library, anonymized.
final class LibraryFile {
  LibraryFile({required this.id, required this.extension, required this.sizeBytes});

  /// sha256 prefix of the library-relative path (the only identifier
  /// that ever reaches an output).
  final String id;

  /// Lower-cased file extension, dot included (format signal only).
  final String extension;

  /// File size in bytes.
  final int sizeBytes;
}

/// The enumerated library plus its in-memory id→path map. The path map
/// never leaves the process.
final class LibraryScan {
  LibraryScan({required this.files, required this.pathFor});

  /// Every file, ordered by id.
  final List<LibraryFile> files;

  /// In-memory id → absolute path.
  final Map<String, String> pathFor;
}

LibraryScan scanLibrary(final String root) {
  final files = <LibraryFile>[];
  final pathFor = <String, String>{};
  for (final entity in Directory(root).listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final relative = _relativePathOf(root, entity);
    final id = _anonymizedId(relative);
    final dot = relative.lastIndexOf('.');
    final extension = dot < 0 ? '' : relative.substring(dot).toLowerCase();
    files.add(LibraryFile(id: id, extension: extension, sizeBytes: entity.lengthSync()));
    pathFor[id] = entity.path;
  }
  files.sort((final a, final b) => a.id.compareTo(b.id));
  return LibraryScan(files: files, pathFor: pathFor);
}

String _relativePathOf(final String root, final File file) =>
    file.path.substring(root.length).replaceFirst(RegExp(r'^[\\/]'), '');

/// sha256 prefix (12 hex chars) of the library-relative path.
String _anonymizedId(final String relativePath) =>
    sha256.convert(utf8.encode(relativePath)).toString().substring(0, 12);

// --- inventory ---

Future<void> _runInventory(final String root, final _Options options) async {
  final scan = scanLibrary(root);
  final totalBytes = scan.files.fold<int>(0, (final sum, final f) => sum + f.sizeBytes);

  var metadataBooks = -1;
  var metadataBytes = 0;
  final dbFile = File('$root/metadata.db');
  if (dbFile.existsSync()) {
    final bytes = dbFile.readAsBytesSync(); // read-only
    metadataBytes = bytes.length;
    try {
      metadataBooks = CalibreDatabase.parse(bytes).books.length;
    } on Object {
      metadataBooks = -1;
    }
  }

  final byExtension = <String, int>{};
  for (final file in scan.files) {
    byExtension[file.extension] = (byExtension[file.extension] ?? 0) + 1;
  }

  final inventory = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'library-inventory',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': contract.platformId,
    'sdk': contract.sdkVersion,
    'commit': contract.commitId,
    'files': scan.files.length,
    'totalBytes': totalBytes,
    'metadataDb': {'books': metadataBooks, 'bytes': metadataBytes},
    'byExtension': byExtension,
    'items': [
      for (final file in scan.files)
        {'id': file.id, 'ext': file.extension, 'sizeBytes': file.sizeBytes},
    ],
  };
  _writeJson(options.out ?? 'library-inventory.json', inventory);
  stdout.writeln(
    'inventory: ${scan.files.length} files, ${_mb(totalBytes)} MB, '
    'metadata.db books: ${metadataBooks < 0 ? 'unreadable' : metadataBooks}',
  );
}

// --- sweep ---

Future<void> _runSweep(final String root, final _Options options) async {
  if (options.checkpoint == null) {
    stderr.writeln('sweep requires --checkpoint=<file> (resumability).');
    exitCode = 64;
    return;
  }
  final scan = scanLibrary(root);
  final entries = scan.files;
  final checkpoint = _Checkpoint.load(options.checkpoint!);
  final pending = List.of(
    entries.where((final entry) => !checkpoint.completed.containsKey(entry.id)),
  );

  stdout.writeln(
    'sweep: ${entries.length} files, ${checkpoint.completed.length} already done, '
    '${pending.length} pending · timeout ${options.timeoutSeconds}s · '
    'concurrency ${options.concurrency}',
  );

  var done = checkpoint.completed.length;
  Future<void> worker() async {
    while (pending.isNotEmpty) {
      final entry = pending.removeLast();
      final record = await _sweepOne(scan, entry, options);
      await checkpoint.record(entry.id, record);
      done++;
      stdout.writeln(
        '[$done/${entries.length}] ${record['status']} ${entry.id} '
        '${entry.extension} ${_mb(entry.sizeBytes)}MB ${record['durationMs']}ms',
      );
    }
  }

  if (pending.isNotEmpty) {
    await Future.wait(List.generate(options.concurrency.clamp(1, pending.length), (_) => worker()));
  }

  final items = entries
      .map((final entry) => checkpoint.completed[entry.id])
      .whereType<Map<String, Object?>>()
      .toList();
  final totals = _totals(entries.length, items);
  final report = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'library-sweep',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': contract.platformId,
    'sdk': contract.sdkVersion,
    'commit': contract.commitId,
    'timeoutSeconds': options.timeoutSeconds,
    'totals': totals,
    'items': items,
  };
  _writeJson(options.out ?? 'library-sweep.json', report);
  stdout.writeln('sweep done: $totals');
}

Map<String, Object?> _totals(final int total, final List<Map<String, Object?>> items) {
  var passed = 0;
  var failed = 0;
  var timeouts = 0;
  var unsupported = 0;
  for (final item in items) {
    switch (item['status']) {
      case 'ok':
        passed++;
      case 'failed':
        failed++;
      case 'timeout':
        timeouts++;
      case 'unsupported':
        unsupported++;
    }
  }
  return {
    'total': total,
    'processed': items.length,
    'passed': passed,
    'failed': failed,
    'timeouts': timeouts,
    'unsupported': unsupported,
    'pending': total - items.length,
  };
}

Future<Map<String, Object?>> _sweepOne(
  final LibraryScan scan,
  final LibraryFile entry,
  final _Options options,
) async {
  final record = <String, Object?>{
    'id': entry.id,
    'ext': entry.extension,
    'sizeBytes': entry.sizeBytes,
  };
  final watch = Stopwatch()..start();
  try {
    final bytes = File(scan.pathFor[entry.id]!).readAsBytesSync();
    final rssBefore = ProcessInfo.currentRss;
    final Uint8List parseInput = bytes;
    String bookFormat;
    try {
      final book = await BookReader.openFromBytes(
        parseInput,
      ).timeout(Duration(seconds: options.timeoutSeconds));
      bookFormat = book.format.name;
    } on TimeoutException {
      watch.stop();
      return record
        ..['status'] = SweepStatus.timeout.name
        ..['durationMs'] = watch.elapsedMilliseconds;
    } on DrmProtectedException catch (error) {
      return _unsupported(record, watch, error, 'parse');
    } on FormatNotSupportedException catch (error) {
      return _unsupported(record, watch, error, 'parse');
    } on PdfEncryptedException catch (error) {
      return _unsupported(record, watch, error, 'parse');
    }
    watch.stop();
    return record
      ..['status'] = SweepStatus.ok.name
      ..['bookFormat'] = bookFormat
      ..['durationMs'] = watch.elapsedMilliseconds
      ..['rssDeltaMb'] = _mb(ProcessInfo.currentRss - rssBefore);
  } on ELivreException catch (error) {
    // A typed library exception the classification above does not
    // recognize: still a failure, but with its exact type recorded.
    watch.stop();
    return record
      ..['status'] = SweepStatus.failed.name
      ..['phase'] = 'parse'
      ..['error'] = error.runtimeType.toString()
      ..['durationMs'] = watch.elapsedMilliseconds;
  } on Object catch (error) {
    // Everything not classified above is a failure worth escalating.
    watch.stop();
    return record
      ..['status'] = SweepStatus.failed.name
      ..['error'] = error.runtimeType.toString()
      ..['durationMs'] = watch.elapsedMilliseconds;
  }
}

Map<String, Object?> _unsupported(
  final Map<String, Object?> record,
  final Stopwatch watch,
  final Object error,
  final String phase,
) {
  watch.stop();
  return record
    ..['status'] = SweepStatus.unsupported.name
    ..['phase'] = phase
    ..['error'] = error.runtimeType.toString()
    ..['durationMs'] = watch.elapsedMilliseconds;
}

// --- sample ---

Future<void> _runSample(final String root, final _Options options) async {
  final scan = scanLibrary(root);
  final supported = scan.files
      .where(
        (final entry) =>
            BookFormat.values.any((final format) => '.${format.name}' == entry.extension),
      )
      .toList();

  // Stratify: per format, the smallest / median / largest file.
  final byFormat = <String, List<LibraryFile>>{};
  for (final entry in supported) {
    byFormat.putIfAbsent(entry.extension, () => <LibraryFile>[]).add(entry);
  }
  final selected = <LibraryFile>[];
  for (final format in byFormat.keys.toList()..sort()) {
    final files = byFormat[format]!..sort((final a, final b) => a.sizeBytes.compareTo(b.sizeBytes));
    for (final index in <int>{0, files.length ~/ 2, files.length - 1}) {
      selected.add(files[index]);
    }
  }

  stdout.writeln(
    'sample: ${supported.length} supported files across ${byFormat.length} '
    'formats; timing ${selected.length} strata (${options.iterations} iterations each)',
  );

  final items = <Map<String, Object?>>[];
  for (final entry in selected) {
    final bytes = File(scan.pathFor[entry.id]!).readAsBytesSync();
    final bucket = _bucketOf(entry);
    final samples = <double>[];
    Object? error;
    for (var i = 0; i < options.iterations + 1; i++) {
      final watch = Stopwatch()..start();
      try {
        final book = await BookReader.openFromBytes(
          bytes,
        ).timeout(Duration(seconds: options.timeoutSeconds));
        // Consume the result so the parse cannot be eliminated.
        contractChecksum = Object.hash(contractChecksum, book.format);
      } on Object catch (caught) {
        error = caught;
      }
      watch.stop();
      if (i > 0) {
        samples.add(watch.elapsedMicroseconds.toDouble());
      }
      if (error != null) {
        break;
      }
    }
    samples.sort();
    final median = samples.isEmpty ? 0.0 : samples[samples.length ~/ 2];
    final p95 = samples.isEmpty
        ? 0.0
        : samples[((samples.length - 1) * 0.95).round().clamp(0, samples.length - 1)];
    contract.recordResult(
      suite: 'e_livre',
      scenario: 'library sample — openFromBytes ${entry.extension} $bucket',
      iterations: samples.length,
      warmup: error == null ? 1 : 0,
      medianMicros: median,
      p95Micros: p95,
      checksum: contractChecksum,
      fixtureId: entry.id,
      sizeBytes: entry.sizeBytes,
      note: error == null ? null : 'skipped: ${error.runtimeType}',
    );
    items.add({
      'id': entry.id,
      'ext': entry.extension,
      'sizeBytes': entry.sizeBytes,
      'status': error == null ? 'ok' : 'error',
      'medianMs': median / 1000,
    });
    stdout.writeln(
      '${error == null ? "ok" : "error"} ${entry.id} ${entry.extension} '
      '${_mb(entry.sizeBytes)}MB median ${(median / 1000).toStringAsFixed(1)}ms',
    );
  }

  final report = <String, Object?>{
    'schemaVersion': 1,
    'suite': 'e_livre',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': contract.platformId,
    'sdk': contract.sdkVersion,
    'commit': contract.commitId,
    'kind': 'library-sample',
    'totals': {'total': supported.length, 'sampled': selected.length, 'formats': byFormat.length},
    'items': items,
    'contractResults': contract.collectedRecords(),
  };
  _writeJson(options.out ?? 'library-sample.json', report);
  stdout.writeln('sample done: ${selected.length} strata');
}

/// Folded checksum over the sample's consumed parse results.
int contractChecksum = 0;

String _bucketOf(final LibraryFile entry) {
  const mb = 1024 * 1024;
  if (entry.sizeBytes < mb) {
    return 'small';
  }
  if (entry.sizeBytes < 10 * mb) {
    return 'medium';
  }
  return 'large';
}

// --- io helpers ---

void _writeJson(final String path, final Map<String, Object?> payload) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(payload)}\n', flush: true);
}

String _mb(final int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

/// Crash-safe checkpoint: records completed items and writes after
/// every item so an interrupted sweep keeps its results and only
/// pending items re-run.
final class _Checkpoint {
  _Checkpoint(this.path, this.completed);

  final String path;
  final Map<String, Map<String, Object?>> completed;
  Future<void> _chain = Future.value();

  static _Checkpoint load(final String path) {
    final file = File(path);
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        return _Checkpoint(
          path,
          (decoded['completed'] as Map<String, Object?>).cast<String, Map<String, Object?>>(),
        );
      } on Object {
        stderr.writeln('checkpoint unreadable — starting fresh.');
      }
    }
    return _Checkpoint(path, <String, Map<String, Object?>>{});
  }

  Future<void> record(final String id, final Map<String, Object?> record) {
    _chain = _chain.then((_) async {
      completed[id] = record;
      final payload = const JsonEncoder.withIndent(
        '  ',
      ).convert({'schemaVersion': 1, 'kind': 'library-sweep-checkpoint', 'completed': completed});
      final file = File(path);
      file.parent.createSync(recursive: true);
      await file.writeAsString('$payload\n', flush: true);
    });
    return _chain;
  }
}
