import 'dart:convert' as convert;
import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  const fixture = 'test/resources/books/epub/elements-of-chemistry.epub';

  group('session search index (isolate transport)', () {
    test('builds in batches, reports coverage, and answers queries', () async {
      final session = await BookSession.openFile(fixture);
      addTearDown(session.dispose);

      final progress = <SearchIndexCoverage>[];
      final coverage = await session.buildSearchIndex(
        sectionsPerBatch: 2,
        identity: const SearchIndexIdentity(publicationId: 'ns:chemistry'),
        onProgress: progress.add,
      );
      expect(coverage.isComplete, isTrue);
      expect(progress, isNotEmpty);
      expect(
        coverage.indexedSections,
        session.book.readingOrder.where((final s) => s.isHtml).length,
      );

      final results = await session.searchIndexed('chemistry', mode: IndexedQueryMode.exact);
      expect(results.hits, isNotEmpty);
      expect(results.coverage.isComplete, isTrue);
      expect(results.isTruncated, isFalse);
      // The hit cuts the original text through the session's own
      // materialization.
      final text = await session.loadDocumentText(results.hits.first.sectionName);
      expect(
        text!.substring(results.hits.first.start, results.hits.first.end).toLowerCase(),
        'chemistry',
      );

      // Prefix queries answer on the same resident index.
      final prefix = await session.searchIndexed('chem', mode: IndexedQueryMode.prefix);
      expect(prefix.hits.length, greaterThanOrEqualTo(results.hits.length));
    });

    test('two sessions keep their indexes separate', () async {
      final first = await BookSession.openFile(fixture);
      final second = await BookSession.openFile(fixture);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.buildSearchIndex();
      // The second session has no index of its own.
      await expectLater(second.searchIndexed('chemistry'), throwsA(isA<SearchIndexException>()));
      // Building the second index does not disturb the first.
      await second.buildSearchIndex();
      expect((await first.searchIndexed('chemistry')).hits, isNotEmpty);
      expect((await second.searchIndexed('chemistry')).hits, isNotEmpty);
    });

    test('drop releases the resident index', () async {
      final session = await BookSession.openFile(fixture);
      addTearDown(session.dispose);

      await session.buildSearchIndex();
      expect((await session.searchIndexCoverage()).indexedSections, greaterThan(0));
      await session.dropSearchIndex();
      // With no resident index, queries fail typed until a new build.
      await expectLater(session.searchIndexed('chemistry'), throwsA(isA<SearchIndexException>()));
      // A coverage report creates an empty resident index again.
      final coverage = await session.searchIndexCoverage();
      expect(coverage.indexedSections, 0);
    });

    test('export and import round trip between sessions over the same book', () async {
      final source = await BookSession.openFile(fixture);
      final target = await BookSession.openFile(fixture);
      addTearDown(source.dispose);
      addTearDown(target.dispose);

      await source.buildSearchIndex(
        identity: const SearchIndexIdentity(publicationId: 'ns:chemistry'),
      );
      final payload = await source.exportSearchIndex();
      expect(payload['schemaVersion'], 1);

      // A cold session validates every section digest through its own
      // materialization before adopting the postings.
      final coverage = await target.importSearchIndex(
        payload,
        identity: const SearchIndexIdentity(publicationId: 'ns:chemistry'),
      );
      expect(coverage.isComplete, isTrue);
      final results = await target.searchIndexed('chemistry');
      expect(results.hits, isNotEmpty);
    });

    test('import refuses an identity absent from the payload', () async {
      final source = await BookSession.openFile(fixture);
      final target = await BookSession.openFile(fixture);
      addTearDown(source.dispose);
      addTearDown(target.dispose);

      // Built without identity: absent fields are not wildcards, so a
      // requesting identity refuses the payload.
      await source.buildSearchIndex();
      final payload = await source.exportSearchIndex();
      await expectLater(
        target.importSearchIndex(
          payload,
          identity: const SearchIndexIdentity(publicationId: 'ns:chemistry'),
        ),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );
      // Without a requested identity the payload adopts as-is.
      final coverage = await target.importSearchIndex(payload);
      expect(coverage.isComplete, isTrue);
    });

    test('import refuses a payload built over a different book', () async {
      final source = await BookSession.openFile(fixture);
      final other = await BookSession.openFile('test/resources/books/epub/mahabharata.epub');
      addTearDown(source.dispose);
      addTearDown(other.dispose);

      await source.buildSearchIndex();
      final payload = await source.exportSearchIndex();
      await expectLater(
        other.importSearchIndex(payload),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );
      // The refused import leaves the target without an index.
      await expectLater(other.searchIndexed('arjuna'), throwsA(isA<SearchIndexException>()));
    });

    test('import refuses corrupted payloads typed', () async {
      final session = await BookSession.openFile(fixture);
      addTearDown(session.dispose);

      await session.buildSearchIndex();
      final payload = await session.exportSearchIndex();
      final broken = <String, Object?>{...payload, 'schemaVersion': 99};
      await expectLater(
        session.importSearchIndex(broken),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );
    });

    test('closed sessions fail index ops typed', () async {
      final session = await BookSession.openFile(fixture);
      await session.buildSearchIndex();
      session.dispose();

      await expectLater(session.searchIndexed('chemistry'), throwsA(isA<SessionClosedException>()));
      await expectLater(session.exportSearchIndex(), throwsA(isA<SessionClosedException>()));
    });

    test('identity mismatch between build calls fails typed', () async {
      final session = await BookSession.openFile(fixture);
      addTearDown(session.dispose);

      await session.searchIndexCoverage(); // Creates the empty index unbound.
      await expectLater(
        session.buildSearchIndex(identity: const SearchIndexIdentity(publicationId: 'ns:x')),
        throwsA(isA<SearchIndexInvalidArgumentException>()),
      );
    });
  });

  group('session search index (inline transport parity)', () {
    test('the inline fallback answers the same queries', () async {
      final bytes = File(fixture).readAsBytesSync();
      final session = await BookSession.open(bytes);
      addTearDown(session.dispose);
      await session.buildSearchIndex(sectionsPerBatch: 3);

      final results = await session.searchIndexed('chemistry');
      expect(results.hits, isNotEmpty);
      // Indexed hits and the eager path agree on the same book.
      final eager = Unseal.parse(bytes) as EpubBook;
      final eagerIndex = await BookSearchIndex.build(eager);
      final eagerResults = eagerIndex.query('chemistry');
      expect(results.hits.first.sectionIndex, eagerResults.hits.first.sectionIndex);
      expect(results.hits.first.start, eagerResults.hits.first.start);
      expect(results.hits.first.end, eagerResults.hits.first.end);
      expect(results.hits.first.score, eagerResults.hits.first.score);
    });
  });

  group('session search index wire payloads', () {
    test('indexed results wire keeps primitives only', () {
      final wire = encodeIndexedSearchResultsWire(
        IndexedSearchResults(
          query: 'teste',
          mode: IndexedQueryMode.prefix,
          isTruncated: true,
          coverage: const SearchIndexCoverage(
            eligibleSections: 2,
            indexedSections: 1,
            pendingSections: 1,
            failedSections: 0,
            totalTokens: 10,
            totalOccurrences: 3,
            termCount: 3,
            isComplete: false,
          ),
          hits: [
            IndexedSearchHit(
              sectionIndex: 0,
              sectionName: 'a.html',
              start: 2,
              end: 7,
              snippet: '…teste…',
              score: 1.25,
            ),
          ],
        ),
      );
      // JSON round trip keeps every field (the worker transports this
      // as a JSON string).
      final decoded = convert.json.decode(convert.json.encode(wire)) as Map<String, Object?>;
      final results = decodeIndexedSearchResultsWire(decoded);
      expect(results.hits.single.score, 1.25);
      expect(results.hits.single.start, 2);
      expect(results.coverage.isComplete, isFalse);
      expect(results.mode, IndexedQueryMode.prefix);
      expect(results.isTruncated, isTrue);
    });
  });
}
