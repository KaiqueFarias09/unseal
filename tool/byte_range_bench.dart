// B02 benchmark: byte-range sessions against the 1.3.0 baselines.
//
// Measures, on the same fixtures: eager parse, file-backed session,
// and remote byte-source session (through the real isolate bridge with
// the host gate) — open latency, first-content latency, a seek loop,
// and the bytes actually transferred. Output goes to build/benchmarks/
// as JSON plus a human-readable table.
//
//     dart run tool/byte_range_bench.dart [--out=build/benchmarks/B02]

import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

const _fixtures = <String, String>{
  'alice-epub': 'test/resources/epub/Alices Adventures in Wonderland.epub',
  'chemistry-epub': 'test/resources/books/epub/elements-of-chemistry.epub',
  'mahabharata-epub': 'test/resources/books/epub/mahabharata.epub',
  'halfpenny-cbz': 'test/resources/books/comic/halfpenny-surprise-1895.cbz',
};

Uint8List _bytes(final String path) => Uint8List.fromList(File(path).readAsBytesSync());

/// The host source: exact slices over memory, counting every range.
final class CountingByteSource implements UnsealByteSource {
  CountingByteSource(this.bytes);

  final Uint8List bytes;
  int requests = 0;
  int bytesServed = 0;

  @override
  int get length => bytes.length;

  @override
  String? get revision => null;

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    requests++;
    bytesServed += count;

    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  @override
  Future<void> close() async {}
}

final class _Row {
  final String shape;
  final int openMicros;
  final int firstContentMicros;
  final int seekLoopMicros;
  final int bytesTransferred;

  _Row(
    this.shape,
    this.openMicros,
    this.firstContentMicros,
    this.seekLoopMicros,
    this.bytesTransferred,
  );
}

Future<void> main(final List<String> arguments) async {
  var out = 'build/benchmarks/B02';
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--out') out = arguments[i + 1];
  }

  final results = <String, Object?>{
    'schemaVersion': 1,
    'benchmark': 'B02 byte-range sessions',
    'shapes': <String>['eager', 'session-file', 'session-source'],
    'fixtures': <Object?>[],
  };

  for (final entry in _fixtures.entries) {
    final name = entry.key;
    final path = entry.value;
    final raw = _bytes(path);
    stdout.writeln('== $name (${raw.length} bytes)');

    // Eager baseline.
    final eagerWatch = Stopwatch()..start();
    final eager = Unseal.parse(raw);
    final eagerOpenMicros = eagerWatch.elapsedMicroseconds;
    final eagerFirst = eager.readingOrder.first.name;
    final eagerFirstWatch = Stopwatch()..start();
    final eagerBytes = _eagerContentFor(eager, eagerFirst);
    final eagerFirstMicros = eagerFirstWatch.elapsedMicroseconds;
    stdout.writeln(
      '  eager          open=${eagerOpenMicros ~/ 1000}ms first=${eagerFirstMicros ~/ 1000}ms '
      'content=${eagerBytes?.length ?? 0}B',
    );

    // File-backed session (the 1.3.0 progressive baseline).
    final fileRows = <_Row>[];
    for (var rep = 0; rep < 2; rep++) {
      final openWatch = Stopwatch()..start();
      final session = await BookSession.openFile(path);
      final openMicros = openWatch.elapsedMicroseconds;
      final firstWatch = Stopwatch()..start();
      final first = await session.loadResource(session.book.readingOrder.first.name);
      final firstMicros = firstWatch.elapsedMicroseconds;
      final seekWatch = Stopwatch()..start();
      var seekBytes = first?.length ?? 0;
      for (final section in session.book.readingOrder.take(5)) {
        seekBytes += (await session.loadResource(section.name))?.length ?? 0;
      }
      final seekMicros = seekWatch.elapsedMicroseconds;
      session.dispose();
      fileRows.add(_Row('session-file', openMicros, firstMicros, seekMicros, seekBytes));
    }
    final fileRow = fileRows.last;
    stdout.writeln(
      '  session-file   open=${fileRow.openMicros ~/ 1000}ms first=${fileRow.firstContentMicros ~/ 1000}ms '
      'seeks(5)=${fileRow.seekLoopMicros ~/ 1000}ms',
    );

    // Remote byte-source session (the B02 path, through the bridge).
    SourceRows? sourceRow;
    for (var rep = 0; rep < 2; rep++) {
      final source = CountingByteSource(raw);
      final openWatch = Stopwatch()..start();
      final session = await BookSession.openSource(source);
      final openMicros = openWatch.elapsedMicroseconds;
      final openRequests = source.requests;
      final openServed = source.bytesServed;
      final firstWatch = Stopwatch()..start();
      final first = await session.loadResource(session.book.readingOrder.first.name);
      final firstMicros = firstWatch.elapsedMicroseconds;
      final seekWatch = Stopwatch()..start();
      var seekBytes = first?.length ?? 0;
      for (final section in session.book.readingOrder.take(5)) {
        seekBytes += (await session.loadResource(section.name))?.length ?? 0;
      }
      final seekMicros = seekWatch.elapsedMicroseconds;
      final totals = <String, int>{
        'requests': source.requests,
        'bytes': source.bytesServed,
        'openRequests': openRequests,
        'openBytes': openServed,
        'contentBytes': seekBytes,
      };
      session.dispose();
      sourceRow = SourceRows(openMicros, firstMicros, seekMicros, totals, first);
    }
    final source = sourceRow!;
    stdout.writeln(
      '  session-source open=${source.openMicros ~/ 1000}ms first=${source.firstContentMicros ~/ 1000}ms '
      'seeks(5)=${source.seekLoopMicros ~/ 1000}ms bytes=${source.totals['bytes']} '
      '(open ${source.totals['openBytes']}, ${((source.totals['openBytes'] ?? 1) / raw.length * 100).toStringAsFixed(1)}% of file)',
    );

    (results['fixtures']! as List<Object?>).add(<String, Object?>{
      'fixture': name,
      'fileBytes': raw.length,
      'eager': <String, Object?>{
        'openMicros': eagerOpenMicros,
        'firstContentMicros': eagerFirstMicros,
        'firstContentBytes': eagerBytes?.length ?? 0,
      },
      'sessionFile': <String, Object?>{
        'openMicros': fileRow.openMicros,
        'firstContentMicros': fileRow.firstContentMicros,
        'seekLoopMicros': fileRow.seekLoopMicros,
      },
      'sessionSource': <String, Object?>{
        'openMicros': source.openMicros,
        'firstContentMicros': source.firstContentMicros,
        'seekLoopMicros': source.seekLoopMicros,
        ...source.totals,
      },
      'parity': <String, Object?>{
        'firstContentMatchesEager': _sameBytes(sourceRow.firstBytes, eagerBytes),
      },
    });
  }

  final outDir = Directory(out);
  outDir.createSync(recursive: true);
  final outFile = File('${outDir.path}/byte-range-bench.json');
  outFile.writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(results)}\n');
  stdout.writeln('wrote ${outFile.path}');
}

bool _sameBytes(final Uint8List? sessionBytes, final Uint8List? eagerBytes) {
  if (sessionBytes == null || eagerBytes == null) return false;
  if (sessionBytes.length != eagerBytes.length) return false;
  for (var i = 0; i < sessionBytes.length; i++) {
    if (sessionBytes[i] != eagerBytes[i]) return false;
  }

  return true;
}

Uint8List? _eagerContentFor(final Book eager, final String path) {
  for (final file in eager.files.html) {
    if (file.path == path) return Uint8List.fromList(convert.utf8.encode(file.content));
  }
  for (final group in [eager.files.images, eager.files.fonts, eager.files.others]) {
    for (final file in group) {
      if (file.path == path) return file.content;
    }
  }
  for (final file in eager.files.css) {
    if (file.path == path) return Uint8List.fromList(convert.utf8.encode(file.content));
  }

  return null;
}

final class SourceRows {
  SourceRows(
    this.openMicros,
    this.firstContentMicros,
    this.seekLoopMicros,
    this.totals,
    this.firstBytes,
  );

  final int openMicros;
  final int firstContentMicros;
  final int seekLoopMicros;
  final Map<String, int> totals;
  final Uint8List? firstBytes;
}
