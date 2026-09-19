import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  final aliceBytes = File(
    'test/resources/epub/Alices Adventures in Wonderland.epub',
  ).readAsBytesSync();
  final linearAlgebraBytes = File('test/resources/epub/linear-algebra.epub').readAsBytesSync();

  // Positions spread over the Alice reading order: section index and
  // the fraction of the section's document text.
  const spreads = <(int, double)>[(0, 0.0), (1, 0.5), (3, 0.25), (7, 0.5), (13, 0.75)];

  group('EpubCfiResolver document cache', () {
    test('warm resolve matches cold resolve field by field', () {
      final book = parseEpubBook(aliceBytes);

      // The first pass is cold (each section is parsed on its first
      // resolve), the second pass hits the per-book cache.
      final cold = <EpubCfiLocation?>[];
      final warm = <EpubCfiLocation?>[];
      for (final (index, fraction) in spreads) {
        final offset = _offsetOf(book, index, fraction);
        final cfi = EpubCfi.parse(book.buildEpubCfi(contentIndex: index, offsetInText: offset));
        cold.add(book.resolveCfi(cfi));
        warm.add(book.resolveCfi(cfi));
      }

      for (var i = 0; i < spreads.length; i++) {
        expect(warm[i], isNotNull);
        expect(warm[i]!.contentIndex, cold[i]!.contentIndex);
        expect(warm[i]!.contentPath, cold[i]!.contentPath);
        expect(warm[i]!.charOffset, cold[i]!.charOffset);
        expect(warm[i]!.textExcerpt, cold[i]!.textExcerpt);
        expect(warm[i]!.elementTrail, cold[i]!.elementTrail);
      }
    });

    test('warm resolve matches a fresh book computed without the cache', () {
      // The reference instance is only used to derive positions; the
      // cached book must reproduce its outputs exactly.
      final reference = parseEpubBook(aliceBytes);
      final cached = parseEpubBook(aliceBytes);

      for (final (index, fraction) in spreads) {
        final offset = _offsetOf(reference, index, fraction);
        final cfi = EpubCfi.parse(
          reference.buildEpubCfi(contentIndex: index, offsetInText: offset),
        );
        final expected = reference.resolveCfi(cfi);
        final actual = cached.resolveCfi(cfi);

        expect(actual, isNotNull);
        expect(actual!.contentIndex, expected!.contentIndex);
        expect(actual.contentPath, expected.contentPath);
        expect(actual.charOffset, expected.charOffset);
        expect(actual.textExcerpt, expected.textExcerpt);
        expect(actual.elementTrail, expected.elementTrail);
      }
    });

    test('warm build produces byte-identical CFIs', () {
      final book = parseEpubBook(aliceBytes);
      for (final (index, fraction) in spreads) {
        final offset = _offsetOf(book, index, fraction);
        final first = book.buildEpubCfi(contentIndex: index, offsetInText: offset);
        final second = book.buildEpubCfi(contentIndex: index, offsetInText: offset);
        expect(second, first);
      }
    });

    test('repeated resolve returns identical results', () {
      final book = parseEpubBook(aliceBytes);
      final cfi = EpubCfi.parse(book.buildEpubCfi(contentIndex: 7, offsetInText: 120));
      final first = book.resolveCfi(cfi)!;
      for (var i = 0; i < 5; i++) {
        final again = book.resolveCfi(cfi)!;
        expect(again.contentIndex, first.contentIndex);
        expect(again.contentPath, first.contentPath);
        expect(again.charOffset, first.charOffset);
        expect(again.textExcerpt, first.textExcerpt);
        expect(again.elementTrail, first.elementTrail);
      }
    });

    test('caches are isolated between book instances of the same fixture', () {
      final bookA = parseEpubBook(aliceBytes);
      final bookB = parseEpubBook(aliceBytes);

      // Warm book A first; book B must still compute its own results.
      final cfiA = EpubCfi.parse(bookA.buildEpubCfi(contentIndex: 7, offsetInText: 120));
      expect(bookA.resolveCfi(cfiA), isNotNull);

      final locationB = bookB.resolveCfi(cfiA);
      final locationA = bookA.resolveCfi(cfiA);
      expect(locationB, isNotNull);
      expect(locationB!.contentIndex, locationA!.contentIndex);
      expect(locationB.contentPath, locationA.contentPath);
      expect(locationB.charOffset, locationA.charOffset);
      expect(locationB.textExcerpt, locationA.textExcerpt);
    });

    test('caches are isolated between different books', () {
      final alice = parseEpubBook(aliceBytes);
      final linearAlgebra = parseEpubBook(linearAlgebraBytes);

      // Warm alice into the shared Expando-backed store first.
      final aliceCfi = EpubCfi.parse(alice.buildEpubCfi(contentIndex: 7, offsetInText: 120));
      expect(alice.resolveCfi(aliceCfi), isNotNull);

      // The other book resolves its own section 0 correctly.
      final otherCfi = EpubCfi.parse(linearAlgebra.buildEpubCfi(contentIndex: 0, offsetInText: 0));
      final location = linearAlgebra.resolveCfi(otherCfi);
      expect(location, isNotNull);
      expect(location!.contentIndex, 0);
      expect(location.contentPath, linearAlgebra.readingOrder.first.name);
      expect(location.charOffset, isNotNull);
      // Alice's cached data must not leak into the other book.
      expect(location.contentPath, isNot(alice.readingOrder[7].name));
    });

    test('repeated out-of-book resolves stay null', () {
      final book = parseEpubBook(aliceBytes);
      final cfi = EpubCfi.parse('epubcfi(/6/9999!/2)');
      expect(book.resolveCfi(cfi), isNull);
      expect(book.resolveCfi(cfi), isNull);
    });
  });
}

/// The document-text offset at [fraction] of the section at [index],
/// derived through the book's own build path.
int _offsetOf(final EpubBook book, final int index, final double fraction) {
  final document = EpubCfiDocument.parse(_htmlOf(book, index).content);
  return (fraction * document.text.length).round().clamp(0, document.text.length);
}

TextFile _htmlOf(final EpubBook book, final int contentIndex) {
  final section = book.readingOrder[contentIndex];
  for (final file in book.files.html) {
    if (file.path == section.name) {
      return file;
    }
  }
  throw StateError('missing HTML file for ${section.name}');
}
