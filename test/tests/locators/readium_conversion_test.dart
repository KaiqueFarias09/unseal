import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

EpubBook _epub(final String name) =>
    parseEpubBook(File('test/resources/books/epub/$name').readAsBytesSync());

/// The conversion outcome contract: exact, approximate, ambiguous, and
/// unsupported stay distinct; verified reuse requires revision,
/// occurrence, and profile context.
void main() {
  group('EPUB conversions', () {
    final book = _epub('accessible-epub-3.epub');

    test('text locator converts exactly with a confirmed CFI', () {
      final file = book.files.html.first;
      final text = documentTextOf(file);
      final sectionIndex = book.readingOrder.toList().indexWhere(
        (final item) => item.name == file.path,
      );
      final start = text.indexOf('the') + 4;

      final outcome = book.toReadiumLocator(
        TextLocator(sectionIndex: sectionIndex, start: start, end: start),
      );

      expect(outcome, isA<ReadiumExact<ReadiumLocator>>());
      final exact = outcome as ReadiumExact<ReadiumLocator>;
      final locator = exact.locator;
      expect(locator.href, file.path);
      expect(locator.href.contains('#'), isFalse);
      expect(locator.locations.fragments.single, startsWith('epubcfi('));
      // The manifest media type travels through.
      expect(locator.type, contains('xhtml'));
      // A point locator quotes its context; the highlight belongs to ranges.
      expect(locator.text!.highlight, isEmpty);
      expect(locator.text!.before, isNotEmpty);
      expect(locator.text!.after, isNotEmpty);

      // A range locator carries the exact highlight.
      final rangeEnd = start + 8 < text.length ? start + 8 : text.length;
      final rangeOutcome = book.toReadiumLocator(
        TextLocator(sectionIndex: sectionIndex, start: start, end: rangeEnd),
      );
      final rangeLocator = (rangeOutcome as ReadiumExact<ReadiumLocator>).locator;
      expect(rangeLocator.text!.highlight, text.substring(start, rangeEnd));

      // The CFI converts back to the same offsets: the full round trip.
      final back = book.toBookLocator(locator);
      expect(back, isA<ReadiumExact<BookLocator>>());
      final textLocator = (back as ReadiumExact<BookLocator>).locator as TextLocator;
      expect(textLocator.sectionIndex, sectionIndex);
      expect(textLocator.start, start);
    });

    test('the Readium locator feeds the official schema shape', () {
      final outcome = book.toReadiumLocator(TextLocator(sectionIndex: 0, start: 0, end: 0));
      final locator = (outcome as ReadiumExact<ReadiumLocator>).locator;
      final json = locator.serialize();
      expect(json.containsKey('href'), isTrue);
      expect(json.containsKey('type'), isTrue);
      // Round-trips through the bounded codec.
      final decoded = readiumLocatorFromJson(readiumLocatorToJsonString(locator));
      expect(decoded.href, locator.href);
    });

    test('foreign hrefs are unsupported, never guessed', () {
      final outcome = book.toBookLocator(
        ReadiumLocator(href: 'elsewhere.xhtml', type: 'application/xhtml+xml'),
      );

      expect(outcome, isA<ReadiumUnsupported<BookLocator>>());
      expect(
        (outcome as ReadiumUnsupported<BookLocator>).reason,
        ReadiumUnsupportedReason.foreignResource,
      );
    });

    test('non-EPUB reflowable books convert approximately', () {
      final document = parseTxtBook(
        Uint8List.fromList(utf8.encode('Chapter one\n\nSome words to locate.\n')),
      );
      final outcome = document.toReadiumLocator(TextLocator(sectionIndex: 0, start: 8, end: 12));

      expect(outcome, isA<ReadiumApproximate<ReadiumLocator>>());
      final approximate = outcome as ReadiumApproximate<ReadiumLocator>;
      expect(approximate.locator.locations.fragments, isEmpty);
      expect(approximate.note, isNotEmpty);
    });

    test('astral offsets survive the CFI round trip', () {
      final opf = '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title id="id">Astral</dc:title>
    <dc:identifier id="id">urn:uuid:astral</dc:identifier>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ch" href="ch.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="ch"/></spine>
</package>''';
      const chapter =
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>'
          '<body><p>alpha \u{1F600} beta \u{1F601} gamma</p></body></html>';
      final opfBytes = utf8.encode(opf);
      final chapterBytes = utf8.encode(chapter);
      final archive = Archive()
        ..addFile(ArchiveFile('content.opf', opfBytes.length, opfBytes))
        ..addFile(ArchiveFile('ch.xhtml', chapterBytes.length, chapterBytes));
      final astralBook = parseEpubBook(Uint8List.fromList(ZipEncoder().encode(archive)));

      // Offset at the low surrogate of the first emoji: the astral
      // scalar boundary the profile and CFI must never split.
      final text = documentTextOf(astralBook.files.html.single);
      final emojiOffset = text.indexOf('\u{1F600}');
      expect(emojiOffset, greaterThanOrEqualTo(0));
      final beta = emojiOffset + 2;

      final outcome = astralBook.toReadiumLocator(
        TextLocator(sectionIndex: 0, start: beta, end: beta + 4),
      );
      expect(outcome, isA<ReadiumExact<ReadiumLocator>>());
      final back = astralBook.toBookLocator((outcome as ReadiumExact<ReadiumLocator>).locator);
      final restored = (back as ReadiumExact<BookLocator>).locator as TextLocator;
      expect(restored.start, beta);
      expect(restored.end, beta + 4);
    });
  });

  group('repeated occurrences', () {
    final repeated = _epub('fxl-repeated-spine.epub');

    test('a repeated href without a hint stays ambiguous', () {
      final order = repeated.readingOrder;
      final repeatedPath = order.first.name;
      expect(order.where((final item) => item.name == repeatedPath).length, greaterThan(1));

      final outcome = repeated.toBookLocator(
        ReadiumLocator(
          href: repeatedPath,
          type: 'application/xhtml+xml',
          locations: ReadiumLocations(fragments: ['partialcfi(/4)']),
        ),
      );

      expect(outcome, isA<ReadiumAmbiguous<BookLocator>>());
      expect((outcome as ReadiumAmbiguous<BookLocator>).candidates.length, greaterThan(1));
    });

    test('an occurrence hint resolves the exact occurrence', () {
      final order = repeated.readingOrder;
      final repeatedPath = order.first.name;
      final secondOccurrence = order.indexed
          .where((final entry) => entry.$2.name == repeatedPath)
          .map((final entry) => entry.$1)
          .toList()[1];

      final outcome = repeated.toBookLocator(
        ReadiumLocator(
          href: repeatedPath,
          type: 'application/xhtml+xml',
          locations: ReadiumLocations(progression: 0.5),
        ),
        occurrenceHint: secondOccurrence,
      );

      expect(outcome, isA<ReadiumApproximate<BookLocator>>());
      final locator = (outcome as ReadiumApproximate<BookLocator>).locator as TextLocator;
      expect(locator.sectionIndex, secondOccurrence);
    });

    test('an occurrence hint outside the href is unsupported', () {
      final order = repeated.readingOrder;
      final repeatedPath = order.first.name;
      final otherIndex = order.indexWhere((final item) => item.name != repeatedPath);

      final outcome = repeated.toBookLocator(
        ReadiumLocator(href: repeatedPath, type: 'application/xhtml+xml'),
        occurrenceHint: otherIndex,
      );

      expect(outcome, isA<ReadiumUnsupported<BookLocator>>());
    });
  });

  group('PDF conversions', () {
    late final PdfBook pdf;
    setUpAll(() {
      pdf = parsePdfBook(File('test/resources/pdf/gutenberg/pg11-generated.pdf').readAsBytesSync());
    });

    test('page locator converts exactly against the host document URI', () {
      final outcome = pdf.toReadiumLocator(
        PageLocator(pageIndex: 2, total: pdf.pageCount),
        documentUri: 'https://library.example/books/dickens.pdf',
      );

      expect(outcome, isA<ReadiumExact<ReadiumLocator>>());
      final locator = (outcome as ReadiumExact<ReadiumLocator>).locator;
      expect(locator.href, 'https://library.example/books/dickens.pdf');
      expect(locator.locations.fragments, ['page=3']);
      // Zero-based native index 2 -> one-based fragment 3.
      expect(locator.locations.totalProgression, closeTo(2 / pdf.pageCount, 1e-12));
    });

    test('a missing host document URI is unsupported, not invented', () {
      final outcome = pdf.toReadiumLocator(PageLocator(pageIndex: 0));

      expect(outcome, isA<ReadiumUnsupported<ReadiumLocator>>());
      expect(
        (outcome as ReadiumUnsupported<ReadiumLocator>).reason,
        ReadiumUnsupportedReason.missingDocumentUri,
      );
    });

    test('page fragments convert one-based to zero-based', () {
      final outcome = pdf.toBookLocator(
        ReadiumLocator(
          href: 'https://library.example/books/dickens.pdf',
          type: 'application/pdf',
          locations: ReadiumLocations(fragments: ['page=1']),
        ),
      );

      expect(outcome, isA<ReadiumExact<BookLocator>>());
      final page = (outcome as ReadiumExact<BookLocator>).locator as PageLocator;
      expect(page.pageIndex, 0);
      expect(page.total, pdf.pageCount);
    });

    test('page fragments outside the page count are unsupported', () {
      for (final fragment in ['page=0', 'page=${pdf.pageCount + 1}']) {
        final outcome = pdf.toBookLocator(
          ReadiumLocator(
            href: 'https://library.example/books/dickens.pdf',
            type: 'application/pdf',
            locations: ReadiumLocations(fragments: [fragment]),
          ),
        );
        expect(outcome, isA<ReadiumUnsupported<BookLocator>>(), reason: fragment);
        expect(
          (outcome as ReadiumUnsupported<BookLocator>).reason,
          ReadiumUnsupportedReason.pageOutOfRange,
        );
      }
    });

    test('isolated progression never proves an exact page', () {
      final outcome = pdf.toBookLocator(
        ReadiumLocator(
          href: 'https://library.example/books/dickens.pdf',
          type: 'application/pdf',
          locations: ReadiumLocations(progression: 0.5),
        ),
      );

      expect(outcome, isA<ReadiumApproximate<BookLocator>>());
    });
  });

  group('comic conversions', () {
    late final ComicBook comic;
    setUpAll(() {
      final png = Uint8List.fromList(const [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        0,
        0,
        0,
        0x0d,
        0x49,
        0x48,
        0x44,
        0x52,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
        0x08,
        0x06,
        0,
        0,
        0,
        0x1f,
        0x15,
        0xc4,
        0x89,
        0,
        0,
        0,
        0x0a,
        0x49,
        0x44,
        0x41,
        0x54,
        0x78,
        0x9c,
        0x63,
        0,
        1,
        0,
        0,
        5,
        0,
        1,
        0x0d,
        0x0a,
        0x2d,
        0xb4,
        0,
        0,
        0,
        0,
        0x49,
        0x45,
        0x4e,
        0x44,
        0xae,
        0x42,
        0x60,
        0x82,
      ]);
      final archive = Archive()
        ..addFile(ArchiveFile('p1.png', png.length, png))
        ..addFile(ArchiveFile('p2.png', png.length, png));
      comic = parseComicBook(Uint8List.fromList(ZipEncoder().encode(archive)));
    });

    test('page locators address the page image resource', () {
      final outcome = comic.toReadiumLocator(PageLocator(pageIndex: 1, total: 2));

      expect(outcome, isA<ReadiumExact<ReadiumLocator>>());
      final locator = (outcome as ReadiumExact<ReadiumLocator>).locator;
      expect(locator.href, 'p2.png');
      expect(locator.type, 'image/png');
      expect(locator.locations.fragments, isEmpty);
    });

    test('unknown page hrefs are unsupported', () {
      final outcome = comic.toBookLocator(ReadiumLocator(href: 'missing.png', type: 'image/png'));

      expect(outcome, isA<ReadiumUnsupported<BookLocator>>());
    });
  });

  group('verified reuse', () {
    final book = _epub('accessible-epub-3.epub');
    final identity = PublicationRevision(
      publicationId: 'test:accessible-epub-3',
      sourceRevision: 'sha256:${'a' * 64}',
      sourceEvidence: SourceEvidence.sha256,
    );
    final orderRevision = RevisionDigest.readingOrderRevision([
      for (final entry in book.readingOrder) (entry.name, entry.isHtml),
    ]);

    test('matching context verifies', () {
      final file = book.files.html.first;
      final snapshot = CanonicalTextSnapshot(
        identity: identity,
        occurrence: SectionOccurrence(
          sectionIndex: 0,
          resourcePath: book.readingOrder[0].name,
          readingOrderRevision: orderRevision,
        ),
        profile: documentTextProfile,
        text: documentTextOf(file).isNotEmpty ? documentTextOf(file) : 'placeholder',
      );
      final verdict = verifyReadiumReuse(
        context: ReadiumLocatorContext(
          identity: identity,
          occurrence: snapshot.occurrence,
          profile: documentTextProfile,
        ),
        snapshot: snapshot,
      );

      expect(verdict, ReadiumReuseVerdict.verified);
    });

    test('a revision, profile, or occurrence change refuses verified reuse', () {
      final file = book.files.html.first;
      final text = documentTextOf(file).isEmpty ? 'placeholder' : documentTextOf(file);
      final occurrence = SectionOccurrence(
        sectionIndex: 0,
        resourcePath: book.readingOrder[0].name,
        readingOrderRevision: orderRevision,
      );
      final snapshot = CanonicalTextSnapshot(
        identity: identity,
        occurrence: occurrence,
        profile: documentTextProfile,
        text: text,
      );
      ReadiumLocatorContext contextOf({
        PublicationRevision? identityOverride,
        TextProfile? profileOverride,
        SectionOccurrence? occurrenceOverride,
      }) => ReadiumLocatorContext(
        identity: identityOverride ?? identity,
        occurrence: occurrenceOverride ?? occurrence,
        profile: profileOverride ?? documentTextProfile,
      );

      final otherIdentity = PublicationRevision(
        publicationId: 'test:accessible-epub-3',
        sourceRevision: 'sha256:${'b' * 64}',
        sourceEvidence: SourceEvidence.sha256,
      );
      expect(
        verifyReadiumReuse(
          context: contextOf(identityOverride: otherIdentity),
          snapshot: snapshot,
        ),
        ReadiumReuseVerdict.incompatibleRevision,
      );

      final otherProfile = TextProfile.of(
        algorithm: 'pdf.reflow',
        options: const {},
        planRevision: 'sha256:${'c' * 64}',
      );
      expect(
        verifyReadiumReuse(
          context: contextOf(profileOverride: otherProfile),
          snapshot: snapshot,
        ),
        ReadiumReuseVerdict.incompatibleProfile,
      );

      expect(
        verifyReadiumReuse(
          context: contextOf(
            occurrenceOverride: SectionOccurrence(
              sectionIndex: 1,
              resourcePath: book.readingOrder[0].name,
              readingOrderRevision: orderRevision,
            ),
          ),
          snapshot: snapshot,
        ),
        ReadiumReuseVerdict.incompatibleOccurrence,
      );

      final unverifiedContext = ReadiumLocatorContext(
        identity: PublicationRevision(publicationId: 'test:memory'),
        occurrence: SectionOccurrence(
          sectionIndex: 0,
          resourcePath: book.readingOrder[0].name,
          readingOrderRevision: null,
        ),
        profile: documentTextProfile,
      );
      expect(
        verifyReadiumReuse(context: unverifiedContext, snapshot: snapshot),
        ReadiumReuseVerdict.unverified,
      );
    });
  });
}
