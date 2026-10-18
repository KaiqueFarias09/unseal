/// PDF session benchmark: open, first content, distant jump, and peak
/// RSS, each measurement in its own process.
///
/// The parent spawns one child per (mode, book); the child runs one
/// scenario, samples its own RSS every 10 ms with `ProcessInfo`, and
/// prints one JSON line. Modes:
///
/// - `eager-parse`    — `Unseal.parse` over resident bytes.
/// - `session-bytes`  — `BookSession.open` over resident bytes.
/// - `session-source` — `BookSession.openSource` over a file-backed
///   host source, so neither the host nor the engine ever holds the
///   whole file (the honest memory lane for the byte-source contract).
///
/// Source scenarios additionally record every served range, so the
/// wire totals (requests, bytes, unique bytes) ride in the same line.
///
///     dart run tool/pdf_session_bench.dart \
///         --out=build/evidence/C01/pdf-session-bench.json
library;

import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

const books = <String>[
  'test/resources/pdf/jbig2/jbig2_huffman_2.pdf',
  'test/resources/books/pdf/elements-of-euclid-pg.pdf',
  'test/resources/pdf/gutenberg/pg2701-generated.pdf',
];

const modes = <String>['eager-parse', 'session-bytes', 'session-source'];

/// The first content request lands past the 20-page reflow sample, the
/// distant jump at the last page.
const firstContentPage = 21;

Future<void> main(final List<String> arguments) async {
  final child = _optionValue(arguments, '--child');
  if (child != null) {
    await _runChild(child, _optionValue(arguments, '--book')!);

    return;
  }

  final outPath = _optionValue(arguments, '--out') ?? 'build/evidence/C01/pdf-session-bench.json';
  final dart = Platform.resolvedExecutable;
  final rows = <Map<String, Object?>>[];
  for (final book in books) {
    for (final mode in modes) {
      final result = await Process.run(dart, [
        'run',
        'tool/pdf_session_bench.dart',
        '--child=$mode',
        '--book=$book',
      ], stdoutEncoding: convert.utf8);
      final line = result.stdout
          .toString()
          .split('\n')
          .firstWhere((final line) => line.startsWith('{'), orElse: () => '');
      if (line.isEmpty) {
        stderr.writeln('child $mode/$book failed:\n${result.stderr}');
        exitCode = 1;

        continue;
      }
      final row = convert.jsonDecode(line) as Map<String, Object?>;
      rows.add(row);
      stdout.writeln(
        '${row['mode']} ${row['bookId']}: '
        'open=${row['t_open_ms']}ms first=${row['t_first_content_ms']}ms '
        'jump=${row['t_jump_ms']}ms peakRss=${row['rss_peak_mb']}MB',
      );
    }
  }

  final file = File(outPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const convert.JsonEncoder.withIndent('  ').convert(<String, Object?>{'schemaVersion': 1, 'generatedBy': 'tool/pdf_session_bench.dart', 'books': books, 'rows': rows})}\n',
  );
  stdout.writeln('wrote $outPath');
}

String? _optionValue(final List<String> arguments, final String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) {
    final inline = arguments.where((final argument) => argument.startsWith('$name='));
    if (inline.isEmpty) return null;

    return inline.first.substring(name.length + 1);
  }

  return arguments[index + 1];
}

Future<void> _runChild(final String mode, final String book) async {
  final file = File(book);
  final bytes = await file.readAsBytes();

  // The scenario baseline sits after the fixture bytes are resident
  // (byte modes) or the file opened (source mode): the delta isolates
  // the library's own footprint from the shared VM/CFE baseline.
  final rssBefore = ProcessInfo.currentRss;
  var peakRss = rssBefore;
  final sampler = Timer.periodic(const Duration(milliseconds: 10), (final _) {
    final rss = ProcessInfo.currentRss;
    if (rss > peakRss) peakRss = rss;
  });

  final openWatch = Stopwatch();
  final firstContentWatch = Stopwatch();
  final jumpWatch = Stopwatch();
  var pageCount = 0;
  var sourceRequests = 0;
  var sourceBytes = 0;
  var sourceUniqueBytes = 0;

  switch (mode) {
    case 'eager-parse':
      openWatch.start();
      final book0 = Unseal.parse(bytes) as PdfBook;
      openWatch.stop();
      pageCount = book0.pageCount;
      firstContentWatch.start();
      final text = book0.pageTexts[firstContentPage - 1].text;
      firstContentWatch.stop();
      jumpWatch.start();
      book0.pageTexts[pageCount - 1].text;
      jumpWatch.stop();
      if (text.isEmpty && pageCount < firstContentPage) {
        stderr.writeln('book has no page $firstContentPage');
      }
    case 'session-bytes':
      openWatch.start();
      final session = await BookSession.open(bytes);
      openWatch.stop();
      pageCount = (session.book as PdfBook).pageCount;
      firstContentWatch.start();
      await session.loadDocumentText('page_$firstContentPage.html');
      firstContentWatch.stop();
      jumpWatch.start();
      await session.loadDocumentText('page_$pageCount.html');
      jumpWatch.stop();
      session.dispose();
    case 'session-source':
      final source = _FileBackedSource(file);
      openWatch.start();
      final session = await BookSession.openSource(source);
      openWatch.stop();
      pageCount = (session.book as PdfBook).pageCount;
      firstContentWatch.start();
      await session.loadDocumentText('page_$firstContentPage.html');
      firstContentWatch.stop();
      jumpWatch.start();
      await session.loadDocumentText('page_$pageCount.html');
      jumpWatch.stop();
      sourceRequests = source.reads.length;
      sourceBytes = source.totalBytes;
      sourceUniqueBytes = _unique(source.reads);
      session.dispose();
      await source.close();
    default:
      stderr.writeln('unknown child mode: $mode');
      exit(2);
  }

  sampler.cancel();
  final peak = math.max(peakRss, ProcessInfo.currentRss);
  stdout.writeln(
    convert.jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'mode': mode,
      'book': book,
      'bookId': book.split('/').last,
      'bytes': bytes.length,
      'pageCount': pageCount,
      't_open_ms': _ms(openWatch),
      't_first_content_ms': _ms(firstContentWatch),
      't_jump_ms': _ms(jumpWatch),
      'rss_peak_mb': double.parse((peak / (1024 * 1024)).toStringAsFixed(1)),
      'rss_before_mb': double.parse((rssBefore / (1024 * 1024)).toStringAsFixed(1)),
      'rss_delta_mb': double.parse(((peak - rssBefore) / (1024 * 1024)).toStringAsFixed(1)),
      if (mode == 'session-source') ...<String, Object?>{
        'source_requests': sourceRequests,
        'source_total_bytes': sourceBytes,
        'source_unique_bytes': sourceUniqueBytes,
      },
    }),
  );
}

int _unique(final List<(int, int)> ranges) {
  final sorted = [...ranges]..sort((final a, final b) => a.$1.compareTo(b.$1));
  var unique = 0;
  var cursor = -1;
  for (final (offset, count) in sorted) {
    final end = offset + count;
    if (end <= cursor) continue;
    unique += end - (offset > cursor ? offset : cursor);
    cursor = end;
  }

  return unique;
}

double _ms(final Stopwatch watch) =>
    double.parse((watch.elapsedMicroseconds / 1000).toStringAsFixed(1));

/// A host-owned source reading exact ranges straight from the file —
/// the resident-file lane the byte-source contract targets. Every range
/// is recorded for the wire ledger.
final class _FileBackedSource implements UnsealByteSource {
  _FileBackedSource(this._file) : length = _file.lengthSync();

  final File _file;
  RandomAccessFile? _handle;

  @override
  final int length;

  @override
  String? get revision => null;

  final List<(int, int)> reads = <(int, int)>[];
  int get totalBytes => reads.fold(0, (final total, final read) => total + read.$2);

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    final handle = _handle ??= await _file.open();
    await handle.setPosition(offset);
    final bytes = await handle.read(count);
    reads.add((offset, count));

    return bytes;
  }

  @override
  Future<void> close() async {
    // Detach before awaiting: dispose and an explicit close can race.
    final handle = _handle;
    _handle = null;
    await handle?.close();
  }
}
