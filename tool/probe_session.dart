import 'dart:io';

import 'package:unseal/unseal.dart';

/// Smoke probe: open a progressive session over a real fixture and
/// exercise the client contract end to end on the VM.
///
/// Format-generic: every supported session format (EPUB, PDF, comics)
/// runs the same op sequence, gets a parity check shaped to its content
/// model and skips what does not apply (CFI addresses EPUB sections
/// only). Line keys stay stable across formats.
Future<void> main() async {
  final path = Platform.environment['PROBE_BOOK'] ?? 'test/resources/books/epub/mahabharata.epub';
  final watch = Stopwatch()..start();
  final session = await BookSession.openFile(path);
  final openMs = watch.elapsedMilliseconds;

  final book = session.book;
  stdout.writeln('open: ${openMs}ms, format=${book.format.name}');
  stdout.writeln(
    'readingOrder=${book.readingOrder.length}, archiveEntries=${book.archiveEntries.length}, '
    'files.html=${book.files.html.length} '
    '(${book is PdfBook ? 'placeholders, one per page' : 'header must be 0'})',
  );
  stdout.writeln('title=${book.metadata.title}, navPoints=${book.navigation.navPoints.length}');

  final first = book.readingOrder.first;
  watch.reset();
  final resource = await session.loadResource(first.name);
  stdout.writeln(
    'loadResource(${first.name}): ${watch.elapsedMilliseconds}ms, '
    '${resource?.length ?? 0} bytes',
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

  // Parity against the eager parse, shaped to the format's content
  // model; CFI roundtrips stay EPUB-only.
  final fullBook = Unseal.parse(File(path).readAsBytesSync());
  switch (fullBook) {
    case final EpubBook full:
      if (results.matches.isNotEmpty) {
        final match = results.matches.first;
        watch.reset();
        final cfi = await session.buildCfi(
          contentIndex: match.sectionIndex,
          offsetInText: match.start,
        );
        final location = await session.resolveCfi(cfi);
        stdout.writeln(
          'cfi roundtrip: build+resolve ${watch.elapsedMilliseconds}ms, '
          'resolved=${location?.charOffset} (expected ${match.start})',
        );
      }
      final fullHtml = full.files.html.firstWhere((f) => f.path == first.name);
      stdout.writeln(
        'parity documentText length: ${text!.length == documentTextOf(fullHtml).length}',
      );

    case final PdfBook full:
      stdout.writeln('cfi roundtrip: skipped (CFI addresses EPUB sections only)');
      stdout.writeln('parity documentText vs eager page 1: ${text == full.pageTexts.first.text}');

    case final ComicBook full:
      stdout.writeln('cfi roundtrip: skipped (CFI addresses EPUB sections only)');
      stdout.writeln(
        'parity page bytes vs eager page 1: '
        '${_listEquals(resource, full.pages.first.content)}',
      );

    default:
      stdout.writeln('parity: skipped (no session format reference for ${fullBook.runtimeType})');
  }

  watch.reset();
  session.dispose();
  stdout.writeln('dispose: ${watch.elapsedMilliseconds}ms');
  try {
    await session.loadResource(first.name);
    stdout.writeln('post-dispose request: UNEXPECTEDLY SUCCEEDED');
    exitCode = 1;
  } on Object catch (error) {
    stdout.writeln('post-dispose request typed failure: ${error.runtimeType}');
  }
}

bool _listEquals(final List<int>? a, final List<int> b) {
  if (a == null || a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }

  return true;
}
