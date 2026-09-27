import 'dart:io';

import 'package:unseal/unseal.dart';

/// Smoke probe: open a progressive session over a real fixture and
/// exercise the client contract end to end on the VM.
Future<void> main() async {
  final path = Platform.environment['PROBE_BOOK'] ?? 'test/resources/books/epub/mahabharata.epub';
  final watch = Stopwatch()..start();
  final session = await BookSession.openFile(path);
  final openMs = watch.elapsedMilliseconds;

  final book = session.book;
  stdout.writeln('open: ${openMs}ms, format=${book.format.name}');
  stdout.writeln(
    'readingOrder=${book.readingOrder.length}, archiveEntries=${book.archiveEntries.length}, '
    'files.html=${book.files.html.length} (header must be 0)',
  );
  stdout.writeln('title=${book.metadata.title}, navPoints=${book.navigation.navPoints.length}');

  final first = book.readingOrder.first;
  watch.reset();
  final chapter = await session.loadResource(first.name);
  stdout.writeln(
    'loadResource(${first.name}): ${watch.elapsedMilliseconds}ms, '
    '${chapter?.length ?? 0} bytes',
  );

  watch.reset();
  final text = await session.loadDocumentText(first.name);
  stdout.writeln('loadDocumentText: ${watch.elapsedMilliseconds}ms, ${text?.length ?? 0} chars');

  watch.reset();
  final results = await session.search('king', maxMatches: 50);
  stdout.writeln(
    'search "king": ${watch.elapsedMilliseconds}ms, ${results.matches.length} matches, '
    'first snippet: ${results.matches.isEmpty ? '' : results.matches.first.snippet.substring(0, 40.clamp(0, results.matches.first.snippet.length))}',
  );

  watch.reset();
  final progression = await session.computeProgression();
  stdout.writeln(
    'progression: ${watch.elapsedMilliseconds}ms, sections=${progression.sectionCount}, '
    'total=${progression.totalCharacters}',
  );

  if (results.matches.isNotEmpty) {
    final match = results.matches.first;
    final cfi = await session.buildCfi(contentIndex: match.sectionIndex, offsetInText: match.start);
    final location = await session.resolveCfi(cfi);
    stdout.writeln(
      'cfi roundtrip: build+resolve ${watch.elapsedMilliseconds}ms, '
      'resolved=${location?.charOffset} (expected ${match.start})',
    );
  }

  // Parity check: resource bytes equal a full parse's bytes for the same path.
  final fullBytes = File(path).readAsBytesSync();
  final fullBook = Unseal.parse(fullBytes);
  final fullHtml = fullBook.files.html.firstWhere((f) => f.path == first.name);
  stdout.writeln('parity documentText length: ${text!.length == documentTextOf(fullHtml).length}');

  watch.reset();
  session.dispose();
  stdout.writeln('dispose: ${watch.elapsedMilliseconds}ms');
  try {
    await session.loadResource(first.name);
    stdout.writeln('post-dispose request: UNEXPECTEDLY SUCCEEDED');
  } on Object catch (error) {
    stdout.writeln('post-dispose request typed failure: ${error.runtimeType}');
  }
}
