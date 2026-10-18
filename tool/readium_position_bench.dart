// D01 benchmark: Readium position-list generation time and resident
// memory (RSS) over eager and session delivery. Evidence, not a gate:
// the numbers land in build/evidence/D01/readium-position-bench.json.
//
// Usage:
//   dart run tool/readium_position_bench.dart \
//     --book test/resources/epub/hefty-water.epub \
//     --out build/evidence/D01/readium-position-bench.json
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:unseal/unseal.dart';

Future<void> main(final List<String> arguments) async {
  var bookPath = 'test/resources/epub/Alices Adventures in Wonderland.epub';
  var outPath = 'build/evidence/D01/readium-position-bench.json';
  for (var index = 0; index < arguments.length - 1; index++) {
    if (arguments[index] == '--book') bookPath = arguments[index + 1];
    if (arguments[index] == '--out') outPath = arguments[index + 1];
  }

  final bytes = Uint8List.fromList(File(bookPath).readAsBytesSync());
  final identity = PublicationRevision(
    publicationId: 'bench:readium-positions',
    sourceRevision: 'sha256:${crypto.sha256.convert(bytes)}',
    sourceEvidence: SourceEvidence.sha256,
  );

  final parseStopwatch = Stopwatch()..start();
  final book = await Unseal.read(bytes);
  parseStopwatch.stop();

  final eagerStopwatch = Stopwatch()..start();
  final rssBefore = ProcessInfo.currentRss;
  final eager = ReadiumPositionListBuilder.ofBook(book, identity: identity);
  final eagerRssDelta = ProcessInfo.currentRss - rssBefore;
  eagerStopwatch.stop();
  final eagerJson = readiumPositionListToJsonString(eager.list);

  final session = await BookSession.open(bytes);
  final openStopwatch = Stopwatch()..start();
  await session.computeProgression();
  openStopwatch.stop();
  final sessionStopwatch = Stopwatch()..start();
  final sessionRssBefore = ProcessInfo.currentRss;
  final built = await ReadiumPositionListBuilder.ofSession(session, identity: identity);
  final sessionRssDelta = ProcessInfo.currentRss - sessionRssBefore;
  sessionStopwatch.stop();
  final sessionJson = readiumPositionListToJsonString(built.list);
  session.dispose();

  // Cancelled builds must stay cheap: a pre-cancelled token stops at the
  // first step.
  final session2 = await BookSession.open(bytes);
  final token = ReadiumPositionCancellationToken()..isCancelled = true;
  final cancelStopwatch = Stopwatch()..start();
  final cancelled = await ReadiumPositionListBuilder.ofSession(session2, cancellation: token);
  cancelStopwatch.stop();
  session2.dispose();

  final report = <String, Object?>{
    'schemaVersion': 1,
    'benchmark': 'tool/readium_position_bench.dart',
    'book': {'path': bookPath, 'bytes': bytes.length},
    'eagerParseMs': parseStopwatch.elapsedMilliseconds,
    'eagerGenerationMs': eagerStopwatch.elapsedMilliseconds,
    'eagerGenerationRssDeltaBytes': eagerRssDelta,
    'eagerPositions': eager.list.total,
    'eagerJsonBytes': eagerJson.length,
    'sessionProgressionMs': openStopwatch.elapsedMilliseconds,
    'sessionGenerationMs': sessionStopwatch.elapsedMilliseconds,
    'sessionGenerationRssDeltaBytes': sessionRssDelta,
    'sessionPositions': built.list.total,
    'sessionCancelledMs': cancelStopwatch.elapsedMilliseconds,
    'sessionCancelledComplete': cancelled.coverage.isComplete,
    'parity': eagerJson == sessionJson,
    'processPeakRssBytes': ProcessInfo.maxRss,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
  };
  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln(
    'readium-position-bench: eager ${eager.list.total} positions in '
    '${report['eagerGenerationMs']} ms, session parity ${report['parity']} '
    '-> ${outFile.path}',
  );
}
