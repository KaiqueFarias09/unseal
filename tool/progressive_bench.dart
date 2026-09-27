// Opening/memory probe for the progressive-reading A/B benchmark
// (docs/specs/progressive-reading/design.md, section 6 metrics contract).
//
// INTENDED PROCESS MODEL: one book per FRESH process, so the RSS delta
// reflects that book's open alone. The sweep driver
// (progressive_bench_sweep.dart) spawns this tool serially; do not loop
// books inside one process.
//
//     dart run tool/progressive_bench.dart --mode=<mode> --book=<path> \
//       [--password=x] [--warm]
//
// Modes implemented now (the CURRENT full-parse path):
//
// * parse-sync         `Unseal.parse(bytes)`, timed on the main isolate.
// * read-isolate       `Unseal.read(bytes)` (background isolate).
// * read-file-isolate  `Unseal.readFile(path)` (file read + isolate).
//
// Modes stubbed for the parallel BookSession implementation — they
// throw UnimplementedError until the session API lands; the JSON
// contract is already identical:
//
// * session-header          bytes -> session header ready (t_open_ms).
// * session-first-content   header + first spine chapter HTML and its
//                           CSS loaded (t_first_content_ms).
//
// Output: ONE JSON object on stdout (nothing else — the sweep driver
// parses stdout). Shape, identical across modes:
//
//     schemaVersion, kind, mode, bookId, bytes,
//     t_open_ms, t_warm_ms (only with --warm), t_first_content_ms,
//     rss_before, rss_after (bytes), rss_delta_mb,
//     rss_warm_before, rss_warm_after, rss_warm_delta_mb (--warm only),
//     bookFormat, readingOrderLength, declaredUncompressedBytes,
//     status, error
//
// rss_before is sampled immediately before the open call (after the
// book bytes are already resident for the byte modes), rss_after right
// after the open returns with the result still referenced; the delta
// therefore isolates the open's retained cost, not the input bytes.
// t_open_ms excludes the input file read for the byte modes; the
// read-file-isolate mode necessarily includes it. The structure fields
// are emitted for every format that has an archive container (EPUB and
// the comic formats).
//
// bookId is the SHA-256 of the resolved absolute path, first 12 hex
// chars — the path itself never reaches the output. Note:
// benchmark/library_sweep.dart deliberately moved private-library ids
// AWAY from path hashes (random ids + a private id map). This tool
// hashes paths per the progressive-reading spec; reports over the
// private library must still live only in the artifacts folder.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unseal/unseal.dart';

/// Modes that exist today, in the order the sweep runs them by default.
const List<String> implementedModes = ['parse-sync', 'read-isolate', 'read-file-isolate'];

/// Session modes reserved for the BookSession implementation.
const List<String> sessionModes = ['session-header', 'session-first-content'];

Future<void> main(final List<String> arguments) async {
  final mode = _optionValue(arguments, '--mode');
  final bookArgument = _optionValue(arguments, '--book');
  final password = _optionValue(arguments, '--password') ?? '';
  final warm = arguments.contains('--warm');

  final record = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'progressive-open-probe',
    'mode': mode,
  };
  if (mode == null || bookArgument == null) {
    stderr.writeln(
      'usage: dart run tool/progressive_bench.dart '
      '--mode=<${[...implementedModes, ...sessionModes].join('|')}> '
      '--book=<path> [--password=x] [--warm]',
    );
    exitCode = 64;
    return;
  }
  if (!_isKnownMode(mode)) {
    stderr.writeln('unknown mode: $mode');
    exitCode = 64;
    return;
  }

  final bookFile = File(bookArgument);
  if (!bookFile.existsSync()) {
    stderr.writeln('book not found: $bookArgument');
    exitCode = 66;
    return;
  }
  final resolved = bookFile.resolveSymbolicLinksSync();
  record['bookId'] = sha256.convert(utf8.encode(resolved)).toString().substring(0, 12);

  try {
    await _runMode(mode, resolved, password: password, warm: warm, record: record);
    record['status'] = 'ok';
  } on UnimplementedError {
    record
      ..['status'] = 'unimplemented'
      ..['error'] = {
        'type': 'UnimplementedError',
        'message': 'session modes land with BookSession (TODO(parent-agent))',
      };
    exitCode = 69;
  } on Object catch (error) {
    record
      ..['status'] = 'fail'
      ..['error'] = {'type': error.runtimeType.toString(), 'message': '$error'};
    exitCode = 1;
  }
  // ONE line, compact: the sweep driver parses this stdout directly.
  stdout.writeln(jsonEncode(record));
}

bool _isKnownMode(final String mode) =>
    implementedModes.contains(mode) || sessionModes.contains(mode);

Future<void> _runMode(
  final String mode,
  final String bookPath, {
  required final String password,
  required final bool warm,
  required final Map<String, Object?> record,
}) async {
  final file = File(bookPath);
  record['bytes'] = file.lengthSync();
  final Uint8List bytes;
  if (mode == 'read-file-isolate') {
    bytes = Uint8List(0); // the mode reads the file inside the timed call
  } else {
    bytes = file.readAsBytesSync(); // untimed; resident before rss_before
  }

  // rss_before is sampled immediately before the open call: by then the
  // byte modes already hold the input bytes, and read-file-isolate has
  // not touched the file yet, so the delta isolates the open itself.
  final rssBefore = ProcessInfo.currentRss;
  final openWatch = Stopwatch()..start();
  final result = await _openOnce(mode, bookPath, bytes, password: password);
  openWatch.stop();
  final rssAfter = ProcessInfo.currentRss;

  record
    ..['t_open_ms'] = _ms(openWatch.elapsedMicroseconds)
    ..['t_first_content_ms'] = null
    ..['rss_before'] = rssBefore
    ..['rss_after'] = rssAfter
    ..['rss_delta_mb'] = _mb(rssAfter - rssBefore);

  if (warm) {
    // The warm open also carries its own RSS pair: after one open the
    // process is settled (JIT compiled, allocators warmed), so
    // rss_warm_delta_mb isolates the retained cost far better than the
    // cold pair, which can go NEGATIVE from startup noise. Prefer it
    // for memory A/B when available.
    final rssWarmBefore = ProcessInfo.currentRss;
    final warmWatch = Stopwatch()..start();
    final warmResult = await _openOnce(mode, bookPath, bytes, password: password);
    warmWatch.stop();
    final rssWarmAfter = ProcessInfo.currentRss;
    record
      ..['t_warm_ms'] = _ms(warmWatch.elapsedMicroseconds)
      ..['rss_warm_before'] = rssWarmBefore
      ..['rss_warm_after'] = rssWarmAfter
      ..['rss_warm_delta_mb'] = _mb(rssWarmAfter - rssWarmBefore);
    _consume(warmResult);
  }
  _consume(result);
  _inspectStructure(result, record: record);
}

/// One open through the path selected by [mode]. Returns the parse
/// result when the mode produces one (kept referenced so the measured
/// work cannot be collected inside the timed window).
Future<Object?> _openOnce(
  final String mode,
  final String bookPath,
  final Uint8List bytes, {
  required final String password,
}) {
  switch (mode) {
    case 'parse-sync':
      return Future<Object?>.value(Unseal.parse(bytes, password: password));
    case 'read-isolate':
      return Unseal.read(bytes, password: password);
    case 'read-file-isolate':
      return Unseal.readFile(bookPath, password: password);
    case 'session-header':
      _openSession(bytes, password: password, firstContent: false);
    case 'session-first-content':
      _openSession(bytes, password: password, firstContent: true);
  }
  throw StateError('unreachable mode: $mode');
}

/// Folds the parse result into a sink so no optimizer can elide the
/// measured work.
int _sink = 0;

void _consume(final Object? result) {
  _sink = Object.hash(_sink, result.runtimeType);
}

/// STUB for the progressive session modes.
///
/// TODO(parent-agent): implement once `BookSession` exists
/// (docs/specs/progressive-reading/design.md). Keep the record contract:
///
/// * session-header — wrap `BookSession.open(bytes, password: password)`
///   in the caller's timed window and set `record['t_open_ms']`; leave
///   `t_first_content_ms` null here.
/// * session-first-content — after the header, load the "first page
///   content" recipe (first spine item document + the CSS files it
///   links) via `session.loadResources([...])` and time that span into
///   `record['t_first_content_ms']`; `t_open_ms` stays header-only so
///   the two session modes keep a comparable opening figure.
///
/// The structure fields (`readingOrderLength`,
/// `declaredUncompressedBytes`) must come from `session.book` (the
/// header), NOT from a second full parse.
///
/// The throw stays until both paths fill those fields; the sweep
/// reports this exit code as `unimplemented`.
void _openSession(
  final Uint8List bytes, {
  required final String password,
  required final bool firstContent,
}) {
  // TODO(parent-agent): BookSession.open / loadResources wiring.
  throw UnimplementedError(
    'session mode (firstContent: $firstContent) requires BookSession '
    '(TODO(parent-agent))',
  );
}

/// Fills the structure fields from the OPEN'S OWN result — no second
/// parse. Untimed, after the measured window. When the session modes
/// land, the parent agent hands `session.book` here instead.
void _inspectStructure(final Object? result, {required final Map<String, Object?> record}) {
  if (result is! Book || result.archiveEntries.isEmpty) {
    return;
  }
  record
    ..['bookFormat'] = result.format.name
    ..['readingOrderLength'] = result.readingOrder.length
    ..['declaredUncompressedBytes'] = result.archiveEntries.fold<int>(
      0,
      (final sum, final entry) => sum + entry.size,
    );
}

String? _optionValue(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

double _ms(final int micros) => double.parse((micros / 1000).toStringAsFixed(1));

double _mb(final int bytes) => double.parse((bytes / (1024 * 1024)).toStringAsFixed(1));
