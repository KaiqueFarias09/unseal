import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import 'book_index_fixture.dart';

void main() {
  group('incremental build and coverage', () {
    test('reports progress per batch and completes', () async {
      final sections = <int, String>{
        for (var i = 0; i < 7; i++) i: 'capítulo $i com palavra$i',
      };
      final progress = <SearchIndexCoverage>[];
      final index = await BookSearchIndex.build(
        buildIndexedBook(sections),
        sectionsPerBatch: 2,
        onProgress: progress.add,
      );
      expect(index.isComplete, isTrue);
      // 7 sections in batches of 2: four onProgress calls.
      expect(progress, hasLength(4));
      expect(progress.first.indexedSections, 2);
      expect(progress.last.indexedSections, 7);
      expect(index.coverage.pendingSections, 0);
      expect(index.coverage.isComplete, isTrue);
    });

    test('queries during construction see partial coverage', () async {
      final index = BookSearchIndex.empty();
      final pending = index.beginEligible([
        const ReadingOrderItem(name: 'a.html', isHtml: true),
        const ReadingOrderItem(name: 'b.html', isHtml: true),
        const ReadingOrderItem(name: 'c.html', isHtml: true),
      ]);
      // One section in, two pending: a query answers from the partial
      // index and carries the coverage that produced it.
      index.addSection(sectionIndex: pending[0].$1, path: pending[0].$2, text: 'primeira palavra');
      final results = index.query('palavra');
      expect(results.hits, hasLength(1));
      expect(results.coverage.isComplete, isFalse);
      expect(results.coverage.pendingSections, 2);
      // Completing the build moves coverage; the same query finds both.
      index.addSection(sectionIndex: pending[1].$1, path: pending[1].$2, text: 'segunda palavra');
      index.addSection(sectionIndex: pending[2].$1, path: pending[2].$2, text: 'terceira palavra');
      expect(index.query('palavra').hits, hasLength(3));
      expect(index.query('palavra').coverage.isComplete, isTrue);
    });

    test('missing section text fails typed and leaves a gap', () async {
      final book = buildIndexedBook(<int, String>{0: 'texto presente'}) as EpubBook;
      // A spine entry pointing at a file that does not exist.
      final gapped = EpubBook(
        navigation: book.navigation,
        files: book.files,
        cover: BinaryFile.empty(),
        package: book.package,
        spinePaths: const <String>['section0.html', 'missing.html'],
        spineIdrefs: const <String>['s0', 'missing'],
      );
      final index = await BookSearchIndex.build(gapped);
      expect(index.isComplete, isFalse);
      expect(index.coverage.failedSections, 1);
      expect(index.coverage.indexedSections, 1);
      // A gapped index never claims completeness.
      expect(index.query('texto').coverage.isComplete, isFalse);
    });

    test('cancellation stops at a batch boundary and coverage freezes', () async {
      final token = SearchIndexCancellationToken();
      final sections = <int, String>{
        for (var i = 0; i < 12; i++) i: 'seção $i conteúdo $i',
      };
      final progress = <SearchIndexCoverage>[];
      final build = BookSearchIndex.build(
        buildIndexedBook(sections),
        sectionsPerBatch: 2,
        cancellation: token,
        onProgress: progress.add,
      );
      // Cancel after the first progress report: the current batch
      // finishes, no further batch runs.
      while (progress.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      token.cancel();
      await expectLater(build, throwsA(isA<SearchIndexCancelledException>()));
      final frozen = progress.last;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // No further batch ran, so no further progress arrived and the
      // counters froze with work pending.
      expect(progress, hasLength(1));
      expect(frozen.isComplete, isFalse);
      expect(frozen.pendingSections, greaterThan(0));
    });

    test('term limit fails typed and records the limit', () async {
      final uniqueWords = List.generate(50, (final i) => 'palavra$i').join(' ');
      final index = BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: uniqueWords}),
        limits: const SearchIndexLimits(maxTerms: 10),
      );
      await expectLater(index, throwsA(isA<SearchIndexLimitExceededException>()));
    });

    test('section cap refuses oversized reading orders', () async {
      final book = buildIndexedBook(<int, String>{0: 'a', 1: 'b', 2: 'c'});
      final index = BookSearchIndex.build(
        book,
        limits: const SearchIndexLimits(maxSections: 2),
      );
      await expectLater(index, throwsA(isA<SearchIndexLimitExceededException>()));
    });

    test('dispose invalidates every later operation', () async {
      final index = await BookSearchIndex.build(buildIndexedBook(<int, String>{0: 'palavra'}));
      index.dispose();
      expect(() => index.query('palavra'), throwsA(isA<SearchIndexDisposedException>()));
      expect(() => index.serialize(), throwsA(isA<SearchIndexDisposedException>()));
      index.dispose(); // Idempotent.
    });
  });
}
