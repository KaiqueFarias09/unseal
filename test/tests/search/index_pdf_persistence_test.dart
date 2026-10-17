import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/indexed_pdf_fixture.dart';

void main() {
  test('PDF indexes persist through the public eager and session APIs with mode checks', () async {
    final bytes = indexedPdfFixture();
    final eager = Unseal.parse(bytes) as PdfBook;
    final index = await BookSearchIndex.build(eager);
    final payload = index.serialize();
    final restored = BookSearchIndex.deserialize(payload, book: Unseal.parse(bytes));

    expect(eager.pageCount, greaterThan(20));
    expect(index.extractionProfileId, eager.canonicalTextProfile!.id);
    expect(restored.query('needle').hits, hasLength(22));
    expect(restored.query('needle').hits.first.start, index.query('needle').hits.first.start);

    final source = await BookSession.open(bytes);
    final reopened = await BookSession.open(bytes);
    addTearDown(source.dispose);
    addTearDown(reopened.dispose);
    final sessionBook = source.book as PdfBook;
    expect(sessionBook.canonicalTextProfile!.options['scope'], 'session-sample');
    expect(sessionBook.canonicalTextProfile!.id, isNot(eager.canonicalTextProfile!.id));
    expect(await source.loadDocumentText('page_1.html'), documentTextOf(eager.files.html.first));
    await source.buildSearchIndex();
    final sessionPayload = await source.exportSearchIndex();
    await reopened.importSearchIndex(sessionPayload);
    expect((await reopened.searchIndexed('needle')).hits, hasLength(22));

    await expectLater(
      reopened.importSearchIndex({
        ...sessionPayload,
        'sections': <Object?>[],
        'terms': <Object?>[],
      }),
      throwsA(isA<SearchIndexIncompatibleException>()),
    );

    await expectLater(
      reopened.importSearchIndex(payload),
      throwsA(isA<SearchIndexIncompatibleException>()),
    );
    expect(
      () => BookSearchIndex.deserialize(sessionPayload, book: eager),
      throwsA(isA<SearchIndexIncompatibleException>()),
    );
    // Refusing an incompatible import preserves the resident good index.
    expect((await reopened.searchIndexed('needle')).hits, hasLength(22));
  });
}
