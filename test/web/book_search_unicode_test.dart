@TestOn('browser')
library;

// Unicode word boundaries on the browser runtime: the wholeWords and
// proximity patterns use `\p{L}`/`\p{N}` property escapes with the
// `unicode` flag, and this suite proves they compile through dart2js
// and match non-Latin text in a real browser (the old ASCII `\b`
// found zero matches for such words on any runtime).
//
// Run with: dart test test/web --platform chrome
import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

Book buildUnicodeEpub(final String html) {
  return EpubBook(
    navigation: Navigation(title: 'Contents', navPoints: const []),
    files: Files(
      images: const [],
      css: const [],
      html: [TextFile(name: 'chapter1.html', type: 'xhtml', path: 'chapter1.html', content: html)],
      fonts: const [],
      others: const [],
    ),
    cover: BinaryFile.empty(),
    package: Epub2Package(
      xmlns: null,
      uniqueIdentifier: 'uid',
      version: '2.0',
      metadata: Epub2Metadata(
        rights: const [],
        contributor: null,
        creator: 'Test Author',
        publisher: null,
        title: 'Unicode Search Fixture',
        date: '2024-01-01',
        language: 'en',
        subject: null,
        description: null,
        identifiers: const ['test-id-1'],
        uniqueIdentifierValue: 'test-id-1',
      ),
      manifest: Manifest(
        items: [ManifestItem(path: 'chapter1.html', id: 'c1', mediaType: 'application/xhtml+xml')],
      ),
      spine: Spine(tocId: null, items: const ['c1']),
      guide: null,
    ),
  );
}

void main() {
  group('Unicode word boundaries on the browser', () {
    test('wholeWords matches Cyrillic through property escapes', () {
      final book = buildUnicodeEpub(
        '<html><body><p>Слово о слове, и ещё одно слово здесь.</p></body></html>',
      );
      final results = book.search('слово', mode: SearchMode.wholeWords);
      // 'Слово' (case-folded) and the standalone 'слово'; the
      // inflected 'слове' does not match.
      expect(results.matches, hasLength(2));

      final text = documentTextOf(book.files.html.single);
      for (final match in results.matches) {
        expect(text.substring(match.start, match.end).toLowerCase(), 'слово');
      }
    });

    test('wholeWords matches Arabic and accented Latin', () {
      final arabic = buildUnicodeEpub('<html><body><p>في الكتاب الكبيرة الكتاب</p></body></html>');
      expect(arabic.search('الكتاب', mode: SearchMode.wholeWords).matches, hasLength(2));

      final portuguese = buildUnicodeEpub('<html><body><p>é ação é</p></body></html>');
      expect(portuguese.search('ação', mode: SearchMode.wholeWords).matches, hasLength(1));
    });

    test('proximity matches Cyrillic words', () {
      final book = buildUnicodeEpub(
        '<html><body><p>кот и пёс сидели рядом, а кот с пёсом дружили</p></body></html>',
      );
      final results = book.search('кот пёс', mode: SearchMode.proximity);
      expect(results.matches, hasLength(1));

      final text = documentTextOf(book.files.html.single);
      final window = text.substring(results.matches.single.start, results.matches.single.end);
      expect(window, contains('кот'));
      expect(window, contains('пёс'));
    });
  });
}
