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
// Session modes over the BookSession API (EPUB + CBZ today; PDF and
// CBR sessions are a later wave — opening one reports the clean typed
// `status: "unsupported"` instead of failing):
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
//     rss_series_mb, rss_peak_mb (only when ps sampling works),
//     rss_warm_before, rss_warm_after, rss_warm_delta_mb (--warm only),
//     bookFormat, readingOrderLength, declaredUncompressedBytes,
//     status ("ok"|"fail"|"unsupported"|"unimplemented"), error
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
// t_first_content_ms times the first content access AFTER the open,
// chosen per book type the way a reader consumes the book: EPUB = the
// first reading-order HTML document's text; PDF = the first page's
// canonical text lines; comics = the first page image bytes. Eager
// parses already materialize all of that at open time, so for the
// full-parse modes the value is near-zero by construction — the honest
// reading is that the first-content cost sits inside t_open_ms; the
// session modes measure the deferred header + first-page load instead
// and report their own timing. Null when the book has no content to
// touch.
//
// rss_series_mb / rss_peak_mb: a dedicated SAMPLING ISOLATE runs
// `ps -o rss= -p <pid>` every ~10 ms for the whole probe run. It is an
// isolate (not a timer on the main isolate) because parse-sync blocks
// the main event loop for the whole open; the sampler's own event loop
// keeps firing. Samples are rounded to 0.1 MB; the peak is the max
// sample. When ps is unavailable the fields are omitted — sampling
// never fails the probe.
//
// bookId is the SHA-256 of the resolved absolute path, first 12 hex
// chars — the path itself never reaches the output. Note:
// benchmark/library_sweep.dart deliberately moved private-library ids
// AWAY from path hashes (random ids + a private id map). This tool
// hashes paths per the progressive-reading spec; reports over the
// private library must still live only in the artifacts folder.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unseal/unseal.dart';

/// Modes that exist today, in the order the sweep runs them by default.
const List<String> implementedModes = ['parse-sync', 'read-isolate', 'read-file-isolate'];

/// Session modes over the BookSession API. PDF/CBR sessions are a
/// later wave (format-expansion-design.md); opening one today reports
/// the typed `unsupported` status.
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
  } on SessionUnsupportedFormatException catch (error) {
    // Session modes over formats the engine does not serve yet (PDF,
    // CBR — later waves of format-expansion-design.md). A clean typed
    // status the sweep aggregates, never a crash.
    record
      ..['status'] = 'unsupported'
      ..['error'] = {'type': 'SessionUnsupportedFormatException', 'message': '$error'};
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
  // RSS series for the WHOLE probe run (bytes load -> open -> warm ->
  // teardown), sampled by a dedicated isolate so the series still
  // covers a parse-sync open that blocks the main event loop.
  final rssSampler = await _RssSampler.start();
  try {
    await _runMeasured(mode, bookPath, password: password, warm: warm, record: record);
  } finally {
    final series = await rssSampler?.stop();
    if (series != null && series.isNotEmpty) {
      record
        ..['rss_series_mb'] = series
        ..['rss_peak_mb'] = series.reduce((final a, final b) => a > b ? a : b);
    }
  }
}

Future<void> _runMeasured(
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

  double? firstContentMs;
  if (result is _SessionCarry) {
    firstContentMs = result.firstContentMs;
  } else {
    // Eager modes: time the first content access on the parsed book
    // (see the file header for the per-format recipe; near-zero for
    // eager parses because everything is already resident).
    firstContentMs = _measureFirstContentEager(result);
  }

  record
    ..['t_open_ms'] = _ms(openWatch.elapsedMicroseconds)
    ..['t_first_content_ms'] = firstContentMs
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
    if (warmResult is _SessionCarry) warmResult.session.dispose();
  }
  _consume(result);
  _inspectStructure(result, record: record);
  // The session isolate must die before the VM exits, or dart run
  // hangs on its runloop after main() returns.
  if (result is _SessionCarry) result.session.dispose();
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
      return _openSession(bytes, password: password, firstContent: false);
    case 'session-first-content':
      return _openSession(bytes, password: password, firstContent: true);
  }
  throw StateError('unreachable mode: $mode');
}

/// Folds the parse result into a sink so no optimizer can elide the
/// measured work.
int _sink = 0;

void _consume(final Object? result) {
  _sink = Object.hash(_sink, result.runtimeType);
}

/// Times the first content access on an eagerly parsed book, per
/// format (file header documents the recipe): PDF = first page's
/// canonical text lines; comics = first page image bytes; everything
/// else = the first reading-order HTML document's text. Returns null
/// when the book has no such content. All of it is memory-resident
/// after an eager parse, so the measured span is the access itself.
double? _measureFirstContentEager(final Object? result) {
  if (result is! Book) {
    return null;
  }

  final watch = Stopwatch()..start();
  var touched = false;
  if (result is PdfBook) {
    final lines = result.pageTexts.isEmpty ? const <PdfTextLine>[] : result.pageTexts.first.lines;
    _sink = Object.hash(_sink, lines.length, lines.isEmpty ? 0 : lines.first.text.length);
    touched = lines.isNotEmpty;
  } else if (result is ComicBook) {
    final page = result.pages.isEmpty ? null : result.pages.first.content;
    _sink = Object.hash(_sink, page?.length);
    touched = page != null && page.isNotEmpty;
  } else {
    final order = result.readingOrder;
    if (order.isEmpty) {
      return null;
    }
    final first = order.firstWhere((final item) => item.isHtml, orElse: () => order.first);
    TextFile? file;
    for (final candidate in result.files.html) {
      if (candidate.path == first.name) {
        file = candidate;
        break;
      }
    }
    file ??= result.files.html.isEmpty ? null : result.files.html.first;
    final content = file?.content;
    _sink = Object.hash(_sink, content?.length);
    touched = content != null && content.isNotEmpty;
  }
  watch.stop();

  return touched ? _ms(watch.elapsedMicroseconds) : null;
}

/// RSS series sampler for the probe process. Runs `ps -o rss= -p <pid>`
/// every ~10 ms — serialized (no new ps before the previous finished) —
/// in a DEDICATED ISOLATE: parse-sync blocks the main isolate's event
/// loop for the whole open, so an in-isolate timer could only sample
/// the two endpoints. Any failure (ps missing, spawn denied) yields an
/// empty series and the fields are omitted; this never fails the probe.
final class _RssSampler {
  _RssSampler._(this._isolate, this._commandPort);

  final Isolate _isolate;
  final SendPort _commandPort;

  /// Spawns the sampler isolate, or returns null when unavailable.
  static Future<_RssSampler?> start() async {
    try {
      final ready = ReceivePort();
      final isolate = await Isolate.spawn(_sampleRss, <Object>[ready.sendPort, pid]);
      final Object? message = await ready.first.timeout(const Duration(seconds: 5));
      if (message is! SendPort) {
        isolate.kill(priority: Isolate.immediate);
        return null;
      }
      return _RssSampler._(isolate, message);
    } on Object {
      return null;
    }
  }

  /// Stops sampling and returns the MB series (0.1 rounded), or an
  /// empty list when nothing was sampled.
  Future<List<double>> stop() async {
    final done = ReceivePort();
    try {
      // The stop message carries its own reply port: the handshake
      // port's listener is already gone (start() consumed it), so a
      // reply there would be silently dropped.
      _commandPort.send(done.sendPort);
      final Object? series = await done.first.timeout(const Duration(seconds: 5));
      return series is List<double> ? series : const <double>[];
    } on Object {
      return const <double>[];
    } finally {
      done.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

/// Sampler-isolate entry: samples until the main isolate sends a reply
/// port, flushes the accumulated series through it, then exits.
Future<void> _sampleRss(final List<Object> arguments) async {
  final ready = arguments[0] as SendPort;
  final targetPid = arguments[1] as int;
  final commands = ReceivePort();
  ready.send(commands.sendPort);

  final series = <double>[];
  Future<void>? inFlight;
  var running = true;

  Timer.periodic(const Duration(milliseconds: 10), (final _) {
    if (!running || inFlight != null) {
      return;
    }
    inFlight = Process.run('ps', <String>['-o', 'rss=', '-p', '$targetPid'])
        .then((final result) {
          final kilobytes = int.tryParse('${result.stdout}'.trim());
          if (kilobytes != null && kilobytes >= 0) {
            series.add(double.parse((kilobytes / 1024).toStringAsFixed(1)));
          }
        })
        .catchError((final Object _) {
          // ps unavailable or failed — skip this sample.
        })
        .whenComplete(() => inFlight = null);
  });

  await for (final message in commands) {
    if (message is! SendPort) {
      continue;
    }
    running = false;
    final pending = inFlight;
    if (pending != null) {
      await pending;
    }
    message.send(series);
    break;
  }
}

/// Opens a session and, for the first-content mode, loads the "first
/// page" recipe: the first HTML spine document plus every CSS it links.
/// The returned carry keeps the session resident for the caller's RSS
/// sampling and reports the separately-timed first-content span.
final class _SessionCarry {
  _SessionCarry(this.session, this.firstContentMs);

  final BookSession session;
  final double? firstContentMs;
}

/// Regexes for the first-content recipe: stylesheet links of the first
/// chapter, resolved the way the reader's server resolves them.
final RegExp _linkTagPattern = RegExp(r'<link\b[^>]*>', multiLine: true, caseSensitive: false);
final RegExp _stylesheetPattern = RegExp(
  r'''rel\s*=\s*["']?stylesheet''',
  multiLine: true,
  caseSensitive: false,
);
final RegExp _hrefPattern = RegExp(r'''href\s*=\s*["']([^"']+)["']''', caseSensitive: false);

Future<_SessionCarry> _openSession(
  final Uint8List bytes, {
  required final String password,
  required final bool firstContent,
}) async {
  final session = await BookSession.open(bytes, password: password);
  if (!firstContent) return _SessionCarry(session, null);

  final order = session.book.readingOrder;
  final firstHtml = order.firstWhere((final item) => item.isHtml, orElse: () => order.first);

  final contentWatch = Stopwatch()..start();
  final source = await session.loadDocumentSource(firstHtml.name) ?? '';
  final cssPaths = <String>{
    for (final tag in _linkTagPattern.allMatches(source))
      if (_stylesheetPattern.hasMatch(tag[0]!) && tag[0]!.contains('href'))
        _resolveSibling(firstHtml.name, _hrefPattern.firstMatch(tag[0]!)?.group(1)),
    for (final match in _hrefPattern.allMatches(source))
      if (match.group(1)!.toLowerCase().endsWith('.css'))
        _resolveSibling(firstHtml.name, match.group(1)),
  }..remove('');

  final targets = <String>{firstHtml.name, ...cssPaths};
  await session.loadResources(targets);
  contentWatch.stop();

  return _SessionCarry(session, _ms(contentWatch.elapsedMicroseconds));
}

/// Resolves a stylesheet [href] against the chapter's directory (the
/// sibling space the resource server uses), or '' for foreign links.
String _resolveSibling(final String chapterPath, final String? href) {
  if (href == null || href.isEmpty) return '';
  final clean = href.split('#').first.split('?').first;
  if (clean.isEmpty) return '';
  if (clean.startsWith('http://') || clean.startsWith('https://') || clean.startsWith('/')) {
    return '';
  }

  final directory = chapterPath.contains('/')
      ? chapterPath.substring(0, chapterPath.lastIndexOf('/'))
      : '';
  final segments = <String>[...directory.split('/'), ...clean.split('/')];
  final resolved = <String>[];
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (resolved.isNotEmpty) resolved.removeLast();
      continue;
    }
    resolved.add(segment);
  }

  return resolved.join('/');
}

/// Fills the structure fields from the OPEN'S OWN result — no second
/// parse. Untimed, after the measured window. When the session modes
/// land, the parent agent hands `session.book` here instead.
void _inspectStructure(final Object? result, {required final Map<String, Object?> record}) {
  final book = result is _SessionCarry ? result.session.book : result;
  if (book is! Book || book.archiveEntries.isEmpty) {
    return;
  }
  final Book resolved = book;
  record
    ..['bookFormat'] = resolved.format.name
    ..['readingOrderLength'] = resolved.readingOrder.length
    ..['declaredUncompressedBytes'] = resolved.archiveEntries.fold<int>(
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
