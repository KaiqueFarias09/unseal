import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../mobi/mobi_fixture_builder.dart';

/// A stored-compression MOBI 6 whose chapter starts are the navigation
/// anchors. The chapter byte lengths are known, so the covering text
/// records of every section — and therefore the exact expected decode
/// work — derive analytically.
typedef _MetricBook = (Uint8List book, List<int> recordLengths);

_MetricBook _buildBook() {
  String chapterText(final String title, final int words) =>
      '<html><body><h1>$title</h1>'
      '<p>${List.filled(words, 'palavra').join(' ')}</p></body></html>';
  final secondText = chapterText('Capítulo 2', 20);
  final thirdText = chapterText('Capítulo 3', 20);

  // The anchors name chapter 2's and chapter 3's <h1> openings in the
  // raw stream. Both targets sit in text right before those tags, so
  // the insertion is attribute-mode and the section boundary lands
  // just after the tag's `>`.
  final linkPrefix =
      '<html><body><h1>Capítulo 1</h1><p>${List.filled(20, 'palavra').join(' ')}</p>';
  const zeros = '0000000000';
  final linkedText =
      '$linkPrefix'
      '<a filepos="$zeros">dois</a>'
      '<a filepos="$zeros">tres</a>'
      '</body></html>';
  // The anchors name chapter 2's and chapter 3's <h1> openings in the
  // actual linked stream: record 2 starts right after record 1. The
  // placeholder already holds the final ten-character width, so the
  // target math matches the encoded record exactly.
  final secondStart = linkedText.length + secondText.indexOf('<h1>');
  final thirdStart = linkedText.length + secondText.length + thirdText.indexOf('<h1>');
  var replacement = 0;
  final linked = Uint8List.fromList(
    convert.utf8.encode(
      linkedText.replaceAllMapped(zeros, (final _) {
        replacement++;

        return (replacement == 1 ? secondStart : thirdStart).toString().padLeft(10, '0');
      }),
    ),
  );
  final second = Uint8List.fromList(convert.utf8.encode(secondText));
  final third = Uint8List.fromList(convert.utf8.encode(thirdText));

  final book = buildPdb('MetricsFixture', [
    buildMobiRecord0(compressionType: 1, textRecordCount: 3, title: 'Metrics'),
    linked,
    second,
    third,
  ]);

  return (book, <int>[linked.length, second.length, third.length]);
}

void main() {
  group('session instrumentation', () {
    test('open materializes no content', () async {
      final (book, _) = _buildBook();
      final session = await BookSession.open(book);
      try {
        final metrics = await session.metrics();
        // Nothing for consumers materialized at open: the content ops
        // never ran.
        expect(metrics.contentBytesMaterialized, 0);
        // The reading-index pass decompressed every text record once;
        // deriving the TOC label windows may re-decode a record each,
        // so the open total stays within two passes over the stream.
        expect(metrics.unitsDecoded, greaterThanOrEqualTo(3));
        expect(metrics.unitsDecoded, lessThanOrEqualTo(6));
        expect(metrics.bytesDecoded, greaterThan(0));
        expect(metrics.sourceBytesRead, greaterThan(0));
      } finally {
        session.dispose();
      }
    });

    test('a section load decodes exactly its covering records', () async {
      final (book, recordLengths) = _buildBook();
      final session = await BookSession.open(book);
      try {
        final before = await session.metrics();

        // The three text records tile the decompressed stream in
        // order; find the section whose source names chapter 2 and
        // derive its covering records from the known record lengths.
        final order = session.book.readingOrder;
        final chapterTwo = order.firstWhere((final item) => item.name == 'chapter00002.html');
        final text = await session.loadDocumentText(chapterTwo.name);
        expect(text, isNotNull);
        expect(text, contains('Capítulo 2'));
        expect(text, isNot(contains('Capítulo 1')));

        final after = await session.metrics();

        // Record 0 is the header; text records are 1..3 with the
        // lengths above. Chapter 2's section starts just inside record
        // 2 and ends just inside record 3 (each chapter opens with its
        // own wrapper), so its span covers records 2 and 3 at most —
        // never record 1, and never a second pass over the book. The
        // open pass's label windows may have warmed a record's store
        // cache, lowering the delta; the served text materializes
        // exactly.
        final deltaUnits = after.unitsDecoded - before.unitsDecoded;
        expect(deltaUnits, lessThanOrEqualTo(2));
        expect(
          after.bytesDecoded - before.bytesDecoded,
          lessThanOrEqualTo(recordLengths[1] + recordLengths[2]),
        );
        // The counter measures the served content (the section
        // source, twice its UTF-16 code-unit count), not the canonical
        // projection of it.
        final source = await session.loadDocumentSource(chapterTwo.name);
        expect(after.contentBytesMaterialized, source!.length * 2);
        expect(text!.length, lessThanOrEqualTo(source.length));
      } finally {
        session.dispose();
      }
    });

    test('re-reading a served section decodes nothing new', () async {
      final (book, _) = _buildBook();
      final session = await BookSession.open(book);
      try {
        final name = session.book.readingOrder.first.name;
        expect(await session.loadDocumentText(name), isNotNull);
        final warm = await session.metrics();

        expect(await session.loadDocumentText(name), isNotNull);
        expect(await session.loadDocumentSource(name), isNotNull);

        final again = await session.metrics();
        expect(again.bytesDecoded, warm.bytesDecoded);
        expect(again.unitsDecoded, warm.unitsDecoded);
      } finally {
        session.dispose();
      }
    });

    test('the cache budget bounds the resident weight', () async {
      final (book, _) = _buildBook();
      final session = await BookSession.open(
        book,
        policy: const SessionPolicy(cacheBytes: 1 << 20),
      );
      try {
        for (final item in session.book.readingOrder) {
          await session.loadDocumentText(item.name);
          await session.loadDocumentSource(item.name);
        }

        final metrics = await session.metrics();
        expect(metrics.cacheBytesResident, lessThanOrEqualTo(1 << 20));
      } finally {
        session.dispose();
      }
    });

    test('an oversized cover drops from the header but still loads', () async {
      final chapter = Uint8List.fromList(
        convert.utf8.encode(
          '<html><body><p>${List.filled(30, 'palavra').join(' ')}</p></body></html>',
        ),
      );
      final book = buildPdb('CoverCapFixture', [
        buildMobiRecord0(compressionType: 1, textRecordCount: 1, firstImageIndex: 2, title: 'Cap'),
        chapter,
        tinyPng,
      ]);

      final eager = Unseal.parse(book) as MobiBook;
      expect(eager.cover.content, tinyPng);

      final session = await BookSession.open(book, policy: const SessionPolicy(coverMaxBytes: 8));
      try {
        expect((session.book as MobiBook).cover.content, isEmpty);
        // The declared delta: the cover loads like any resource.
        final loaded = await session.loadResource('cover.png');
        expect(loaded, isNotNull);
        expect(loaded, tinyPng);
      } finally {
        session.dispose();
      }
    });
  });
}
