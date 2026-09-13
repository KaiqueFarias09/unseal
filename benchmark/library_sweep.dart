// Robustness sweep and stratified sample benchmarks over a PRIVATE
// Calibre library, run entirely READ-ONLY and strictly opt-in.
//
// Nothing runs implicitly: the library root must be supplied through
// `--library=<path>` (or the `ELIVRE_CALIBRE_LIBRARY` /
// `ELIVRE_BENCH_LIBRARY` environment variables), and the tracked
// benchmark suites never invoke this tool. The library is never
// written to.
//
// PRIVACY MODEL. File paths, titles, authors and file names never
// reach any output of this tool. Every file is identified by a RANDOM
// identifier generated once and persisted by the operator through
// `--id-map=<file>`; the id map is the ONLY place path and id meet and
// must stay outside the repository (the artifacts folder). Path-hash
// ids were retired: truncated hashes of paths are too weak an
// anonymization for private data.
//
// Modes:
//
//     dart run benchmark/library_sweep.dart inventory \
//       --library=<root> --id-map=<file> --out=<inventory.json>
//
//     dart run benchmark/library_sweep.dart sweep \
//       --library=<root> --id-map=<file> --checkpoint=<file> \
//       [--out=<sweep.json>] [--timeout-seconds=120] [--concurrency=2]
//
//     dart run benchmark/library_sweep.dart sample \
//       --library=<root> --id-map=<file> --out=<sample.json> [--iterations=5]
//
// * inventory  one pass listing every file (class + size) plus a
//   read-only parse of metadata.db's book count.
// * sweep      robustness pass over every candidate book through a
//   killable worker isolate with a per-book timeout; resumable via an
//   atomically written checkpoint. Classification: book / sidecar /
//   unsupported / drm / error / timeout — DRM-protected and encrypted
//   files are unsupported-capability, never crashes.
// * sample     repeated timing over a stratified per-format sample
//   (smallest / median / largest per format), emitted as
//   schemaVersion-1 benchmark contract rows.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:e_livre/e_livre.dart';

import 'json_report.dart' as contract;

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
      'ELIVRE_CALIBRE_LIBRARY / ELIVRE_BENCH_LIBRARY. The private corpus '
      'is strictly opt-in; nothing is discovered implicitly.',
    );
    exitCode = 64;
    return;
  }
  if (options.idMap == null) {
    stderr.writeln(
      '--id-map=<file> is required: random ids are persisted there so '
      'reports stay anonymized across resumes. Keep the map OUTSIDE the '
      'repository (artifacts only) — it is the one file that joins ids '
      'to paths.',
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
    '--library=<root> --id-map=<file> [--out=<file>] [--checkpoint=<file>] '
    '[--timeout-seconds=<n>] [--concurrency=<n>] [--iterations=<n>]',
  );
}

// --- options ---

final class _Options {
  String? library;
  String? out;
  String? checkpoint;
  String? idMap;
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
    } else if (argument.startsWith('--id-map=') && value != null) {
      options.idMap = value;
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

// --- classification ---

/// Readable sweep status of one item.
enum SweepStatus { book, sidecar, unsupported, drm, error, timeout }

/// Extensions the parser supports as [BookFormat] values.
final Set<String> _bookExtensions = <String>{
  for (final format in BookFormat.values) '.${format.name}',
};

/// Known book containers the library may hold that the parser
/// deliberately does not support (legacy Kindle etc.); they stay on the
/// parse track so DRM and unsupported outcomes are typed, not guessed.
final Set<String> _legacyBookExtensions = <String>{'.azw', '.prc', '.tpz', '.azw1', '.kfx'};

bool _isBookCandidate(final String extension) =>
    _bookExtensions.contains(extension) || _legacyBookExtensions.contains(extension);

// --- library enumeration ---

/// One file of the library, anonymized.
final class LibraryFile {
  LibraryFile({
    required this.id,
    required this.extension,
    required this.sizeBytes,
    required this.isBookCandidate,
  });

  /// The RANDOM persisted id; the only identifier that ever reaches an
  /// output.
  final String id;

  /// Lower-cased file extension, dot included (format signal only).
  final String extension;

  /// File size in bytes.
  final int sizeBytes;

  /// Whether the file goes through the parser.
  final bool isBookCandidate;
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

LibraryScan scanLibrary(final String root, final Map<String, String> idMap) {
  final files = <LibraryFile>[];
  final pathFor = <String, String>{};
  for (final entity in Directory(root).listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final relative = _relativePathOf(root, entity);
    final id = idMap.putIfAbsent(relative, _randomId);
    final dot = relative.lastIndexOf('.');
    final extension = dot < 0 ? '' : relative.substring(dot).toLowerCase();
    files.add(
      LibraryFile(
        id: id,
        extension: extension,
        sizeBytes: entity.lengthSync(),
        isBookCandidate: _isBookCandidate(extension),
      ),
    );
    pathFor[id] = entity.path;
  }
  files.sort((final a, final b) => a.id.compareTo(b.id));
  return LibraryScan(files: files, pathFor: pathFor);
}

String _relativePathOf(final String root, final File file) =>
    file.path.substring(root.length).replaceFirst(RegExp(r'^[\\/]'), '');

/// A fresh random identifier (not derived from the path).
String _randomId() {
  final random = Random.secure();
  final bytes = Uint8List(6);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes.map((final b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The persisted id↔path map. Lives only where the operator puts it
/// (artifacts); the tool refuses to run without it.
final class PrivateIdMap {
  PrivateIdMap(this.path, this.byPath);

  final String path;
  final Map<String, String> byPath;

  static PrivateIdMap load(final String path) {
    final file = File(path);
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        return PrivateIdMap(
          path,
          (decoded['byPath'] as Map<String, Object?>).cast<String, String>(),
        );
      } on Object {
        stderr.writeln('id map unreadable — regenerating (ids will change).');
      }
    }
    return PrivateIdMap(path, <String, String>{});
  }

  /// Persists atomically (temp file + rename on the same volume).
  void save() {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'schemaVersion': 1, 'kind': 'library-private-id-map', 'generatedAt': DateTime.now().toUtc().toIso8601String(), 'byPath': byPath})}\n',
      flush: true,
    );
    tmp.renameSync(file.path);
  }
}

// --- inventory ---

Future<void> _runInventory(final String root, final _Options options) async {
  final idMap = PrivateIdMap.load(options.idMap!);
  final scan = scanLibrary(root, idMap.byPath);
  idMap.save();

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
  var bookCandidates = 0;
  for (final file in scan.files) {
    byExtension[file.extension] = (byExtension[file.extension] ?? 0) + 1;
    if (file.isBookCandidate) {
      bookCandidates++;
    }
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
    'bookCandidates': bookCandidates,
    'metadataDb': {'books': metadataBooks, 'bytes': metadataBytes},
    'byExtension': byExtension,
    'items': [
      for (final file in scan.files)
        {
          'id': file.id,
          'ext': file.extension,
          'sizeBytes': file.sizeBytes,
          'track': file.isBookCandidate ? 'book' : 'sidecar',
        },
    ],
  };
  _writeJson(options.out ?? 'library-inventory.json', inventory);
  stdout.writeln(
    'inventory: ${scan.files.length} files, ${_mb(totalBytes)} MB, '
    '$bookCandidates book candidates, '
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
  final idMap = PrivateIdMap.load(options.idMap!);
  final scan = scanLibrary(root, idMap.byPath);
  idMap.save();
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
      final record = entry.isBookCandidate
          ? await _sweepBook(scan, entry, options)
          : _sidecarRecord(entry);
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
  final report = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'library-sweep',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': contract.platformId,
    'sdk': contract.sdkVersion,
    'commit': contract.commitId,
    'timeoutSeconds': options.timeoutSeconds,
    'totals': _totals(entries.length, items),
    'items': items,
  };
  _writeJson(options.out ?? 'library-sweep.json', report);
  stdout.writeln('sweep done: ${report['totals']}');
}

Map<String, Object?> _sidecarRecord(final LibraryFile entry) {
  return <String, Object?>{
    'id': entry.id,
    'ext': entry.extension,
    'sizeBytes': entry.sizeBytes,
    'status': SweepStatus.sidecar.name,
    'durationMs': 0,
  };
}

Map<String, Object?> _totals(final int total, final List<Map<String, Object?>> items) {
  final counts = <String, int>{};
  for (final item in items) {
    final status = item['status'] as String? ?? 'error';
    counts[status] = (counts[status] ?? 0) + 1;
  }
  return {
    'total': total,
    'processed': items.length,
    'book': counts['book'] ?? 0,
    'sidecar': counts['sidecar'] ?? 0,
    'unsupported': counts['unsupported'] ?? 0,
    'drm': counts['drm'] ?? 0,
    'fail': counts['fail'] ?? 0,
    'timeouts': counts['timeout'] ?? 0,
    'pending': total - items.length,
  };
}

/// Parses one book candidate in a killable worker isolate.
///
/// The isolate is spawned per book and KILLED on timeout — a wedged
/// parser cannot leak past its deadline the way a deadline loop would.
Future<Map<String, Object?>> _sweepBook(
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
  final rssBefore = ProcessInfo.currentRss;
  final bytes = File(scan.pathFor[entry.id]!).readAsBytesSync();
  final port = ReceivePort();
  final errorPort = ReceivePort();
  final done = Completer<Map<String, Object?>>();
  late final Isolate isolate;

  errorPort.listen((final message) {
    if (!done.isCompleted) {
      done.complete({
        'status': SweepStatus.error.name,
        'error': {'type': 'IsolateError', 'message': '$message'},
        'phase': 'spawn',
      });
    }
  });
  port.listen((final message) {
    if (done.isCompleted) {
      return;
    }
    final payload = message as Map;
    done.complete(Map<String, Object?>.from(payload));
  });

  try {
    isolate = await Isolate.spawn(_parseJob, _ParseJob(port.sendPort, bytes), errorsAreFatal: true);
  } on Object catch (error) {
    port.close();
    errorPort.close();
    watch.stop();
    return record
      ..['status'] = SweepStatus.error.name
      ..['error'] = {'type': error.runtimeType.toString(), 'phase': 'spawn'}
      ..['durationMs'] = watch.elapsedMilliseconds;
  }

  final timeout = Duration(seconds: options.timeoutSeconds);
  final result = await done.future.timeout(
    timeout,
    onTimeout: () {
      isolate.kill(priority: Isolate.immediate);
      return <String, Object?>{
        'status': SweepStatus.timeout.name,
        'error': {'type': 'TimeoutException', 'phase': 'parse'},
      };
    },
  );
  port.close();
  errorPort.close();
  watch.stop();

  record['durationMs'] = watch.elapsedMilliseconds;
  if (result['bookFormat'] is String) {
    record['bookFormat'] = result['bookFormat'];
  }
  if (result['error'] is Map) {
    record['error'] = result['error'];
  }
  switch (result['status']) {
    case 'book':
      record['status'] = SweepStatus.book.name;
      record['rssDeltaMb'] = _mb(ProcessInfo.currentRss - rssBefore);
    case 'drm':
      record['status'] = SweepStatus.drm.name;
      record['phase'] = 'parse';
    case 'unsupported':
      record['status'] = SweepStatus.unsupported.name;
      record['phase'] = 'parse';
    case 'fail':
      record['status'] = SweepStatus.error.name;
      record['phase'] = 'parse';
    default:
      record['status'] = result['status'];
  }
  return record;
}

/// Wire message for the worker isolate.
final class _ParseJob {
  _ParseJob(this.sendPort, this.bytes);

  final SendPort sendPort;
  final Uint8List bytes;
}

/// Worker entry: parses through the public async reader (it dispatches
/// every format correctly, including the zip-refined 7-Zip containers)
/// and classifies typed outcomes. A kill of this isolate also tears
/// down any nested reader isolate it spawned.
Future<void> _parseJob(final _ParseJob job) async {
  try {
    final book = await BookReader.openFromBytes(job.bytes);
    job.sendPort.send({'status': 'book', 'bookFormat': book.format.name});
  } on Object catch (error) {
    job.sendPort.send(_classifyParseError(error));
  }
}

/// Typed classification of one parse failure.
Map<String, Object?> _classifyParseError(final Object error) {
  if (error is DrmProtectedException || error is PdfEncryptedException) {
    return {
      'status': 'drm',
      'error': {'type': error.runtimeType.toString()},
    };
  }
  if (error is FormatNotSupportedException) {
    return {
      'status': 'unsupported',
      'error': {'type': error.runtimeType.toString()},
    };
  }
  return {
    'status': 'fail',
    'error': {'type': error.runtimeType.toString()},
  };
}

// --- sample ---

Future<void> _runSample(final String root, final _Options options) async {
  final idMap = PrivateIdMap.load(options.idMap!);
  final scan = scanLibrary(root, idMap.byPath);
  idMap.save();
  final supported = scan.files.where((final entry) => entry.isBookCandidate).toList();

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
    'sample: ${supported.length} book candidates across ${byFormat.length} '
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
      final parsed = await _timedParse(bytes, options);
      watch.stop();
      if (parsed['status'] == 'book') {
        // Consume the result so the parse cannot be eliminated.
        contractChecksum = Object.hash(contractChecksum, parsed['bookFormat']);
      } else {
        error = parsed['error'];
      }
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
    final ok = error == null;
    contract.recordResult(
      suite: 'e_livre',
      scenario: 'library sample — openFromBytes ${entry.extension} $bucket',
      iterations: samples.length,
      warmup: ok ? 1 : 0,
      medianMicros: median,
      p95Micros: p95,
      checksum: contractChecksum,
      fixtureId: entry.id,
      sizeBytes: entry.sizeBytes,
      error: ok ? null : _structuredError(error),
    );
    items.add({
      'id': entry.id,
      'ext': entry.extension,
      'sizeBytes': entry.sizeBytes,
      'status': ok ? SweepStatus.book.name : SweepStatus.error.name,
      if (!ok) 'error': error,
      'medianMs': median / 1000,
    });
    stdout.writeln(
      '${ok ? "ok" : "fail"} ${entry.id} ${entry.extension} '
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

/// One timed parse through a killable worker isolate.
Future<Map<String, Object?>> _timedParse(final Uint8List bytes, final _Options options) async {
  final port = ReceivePort();
  final done = Completer<Map<String, Object?>>();
  port.listen((final message) {
    if (!done.isCompleted) {
      done.complete(Map<String, Object?>.from(message as Map));
    }
  });
  late final Isolate isolate;
  isolate = await Isolate.spawn(_parseJob, _ParseJob(port.sendPort, bytes));
  final result = await done.future.timeout(
    options.timeoutSeconds.seconds,
    onTimeout: () {
      isolate.kill(priority: Isolate.immediate);
      return <String, Object?>{
        'status': 'timeout',
        'error': {'type': 'TimeoutException', 'phase': 'parse'},
      };
    },
  );
  port.close();
  return result;
}

/// Folded checksum over the sample's consumed parse results.
int contractChecksum = 0;

/// Normalizes any failure into the structured error contract field.
Map<String, Object?> _structuredError(final Object? error) {
  if (error is Map) {
    return {
      'type': (error['type'] ?? 'unknown').toString(),
      if (error['phase'] != null) 'phase': error['phase'],
    };
  }
  return {'type': error?.runtimeType.toString() ?? 'unknown', 'phase': 'parse'};
}

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

/// Writes a JSON payload atomically: temp file on the SAME volume, then
/// rename, so a crash can never leave a torn report or checkpoint.
void _writeJson(final String path, final Map<String, Object?> payload) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final tmp = File('${file.path}.tmp');
  tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(payload)}\n', flush: true);
  tmp.renameSync(file.path);
}

String _mb(final int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

extension on int {
  Duration get seconds => Duration(seconds: this);
}

/// Crash-safe sweep checkpoint. Every completed item is recorded and
/// the file is atomically rewritten (temp + fsync + rename on the same
/// volume), so an interrupted sweep keeps its results and only pending
/// items re-run.
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
    _chain = _chain.then((_) {
      completed[id] = record;
      final payload = const JsonEncoder.withIndent(
        '  ',
      ).convert({'schemaVersion': 1, 'kind': 'library-sweep-checkpoint', 'completed': completed});
      final file = File(path);
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync('$payload\n', flush: true);
      tmp.renameSync(file.path);
    });
    return _chain;
  }
}

/// Kept for id stability notes: the retired scheme hashed the relative
/// path; old reports carrying such ids live in the quarantine folder.
String retiredPathHashId(final String relativePath) =>
    sha256.convert(utf8.encode(relativePath)).toString().substring(0, 12);
