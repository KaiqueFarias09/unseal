import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// The ANN06 acceptance: one anchor, captured over the same characters
/// a search hit selected, survives reopening and full ↔ session mode
/// switches on a PDF beyond the 20-page session sample, with regions,
/// ranges and the index agreeing — and an incompatible revision
/// invalidating the index while the anchor migrates explicitly.
void main() {
  final corpusDir = Directory('test/resources/pdf/gutenberg');
  if (!corpusDir.existsSync()) {
    fail('missing $corpusDir; run `dart run tool/fetch_pdf_corpus.dart`');
  }
  final books =
      corpusDir
          .listSync()
          .whereType<File>()
          .where((final file) => file.path.endsWith('.pdf'))
          .toList()
        ..sort((final a, final b) => a.path.compareTo(b.path));
  if (books.isEmpty) {
    fail('empty $corpusDir; run `dart run tool/fetch_pdf_corpus.dart`');
  }

  late File longBook;
  late Uint8List bytes;
  late String sourceRevision;
  late PublicationRevision identity;
  late PdfBook book;
  late int anchorPage;
  late PdfPageStructure structure;
  late String pageText;
  late (int, int) quoteSpan;

  setUpAll(() {
    longBook = books.firstWhere(
      (final file) => parsePdfBook(file.readAsBytesSync()).pageCount > 20,
      orElse: () => throw StateError('the corpus must carry a book over 20 pages'),
    );
    bytes = longBook.readAsBytesSync();
    sourceRevision = RevisionDigest.hex(SHA256Digest().process(bytes));
    identity = PublicationRevision(
      publicationId: 'gutenberg:anchor-acceptance',
      sourceRevision: sourceRevision,
      sourceEvidence: SourceEvidence.sha256,
    );
    book = parsePdfBook(bytes);

    // Anchor mid-document, in body text: the session's sampled reflow
    // keeps the page center, so the mode-switch case stays the
    // unambiguous excerpt the acceptance asks for.
    anchorPage = book.pageCount ~/ 2;
    structure = buildPdfPageStructure(book: book, pageIndex: anchorPage);
    pageText = structure.canonicalText;
    quoteSpan = _midPageQuote(pageText);
  });

  /// Feeds [index] with every section's canonical document text.
  void indexAllSections(final BookSearchIndex index) {
    final order = book.readingOrder;
    index.beginEligible(order);
    for (var section = 0; section < order.length; section++) {
      index.addSection(
        sectionIndex: section,
        path: order[section].name,
        text: documentTextOf(
          book.files.html.firstWhere((final file) => file.path == order[section].name),
        ),
      );
    }
  }

  group('PDF anchors across modes and reopenings', () {
    test('an indexed hit captures as a verified anchor over the same characters', () {
      final index = BookSearchIndex.empty(
        identity: SearchIndexIdentity(
          publicationId: identity.publicationId,
          sourceRevision: sourceRevision,
          sourceEvidence: SearchSourceEvidence.sha256,
        ),
      );
      indexAllSections(index);

      final quote = pageText.substring(quoteSpan.$1, quoteSpan.$2);
      final tokens = quote.split(RegExp(r'\s+')).take(3).toList(growable: false);
      final results = index.query(tokens.join(' '));
      expect(results.hits, isNotEmpty);
      final hit = results.hits.firstWhere(
        (final candidate) =>
            candidate.sectionIndex == anchorPage &&
            candidate.start >= quoteSpan.$1 &&
            candidate.end <= quoteSpan.$2,
        orElse: () => throw StateError('the indexed hit must sit inside the quoted span'),
      );

      // The canonical snapshot the anchor binds to is the page's own
      // document text — the same space search and CFI address.
      final snapshot = structure.canonicalSnapshot(identity: identity);
      expect(snapshot.text, documentTextOf(book.files.html[anchorPage]));

      final anchor = DurableAnnotations.capture(snapshot: snapshot, start: hit.start, end: hit.end);
      expect(anchor.quote.exact, pageText.substring(hit.start, hit.end));
      expect(anchor.quote.exact, isNotEmpty);

      // The verified anchor round-trips the codec (identity exportable)
      // and survives a fresh re-parse byte for byte.
      final decoded = decodeAnchor(encodeAnchor(anchor));
      final reopened = buildPdfPageStructure(book: parsePdfBook(bytes), pageIndex: anchorPage);
      final resolution = DurableAnnotations.resolve(
        anchor: decoded,
        targets: [reopened.canonicalSnapshot(identity: identity)],
      );

      final resolved = resolution as AnchorResolved;
      expect(resolved.verified, isTrue);
      expect(resolved.basis, AnchorMatchBasis.identityReuse);
      expect(resolved.range.text, anchor.quote.exact);
      expect(resolved.range.start, hit.start);
      expect(resolved.range.end, hit.end);
    });

    test('switching to the session sample demands migration, then resolves', () async {
      final snapshot = structure.canonicalSnapshot(identity: identity);
      final anchor = DurableAnnotations.capture(
        snapshot: snapshot,
        start: quoteSpan.$1,
        end: quoteSpan.$2,
      );

      final session = await BookSession.open(bytes);
      addTearDown(session.dispose);
      final sessionStructure = await session.loadPdfPageStructure(anchorPage);
      expect(sessionStructure, isNotNull);
      final sessionText = await session.loadDocumentText(sessionStructure!.resourcePath);
      expect(sessionText, sessionStructure.canonicalText);

      final sessionSnapshot = sessionStructure.canonicalSnapshot(identity: identity);

      // The sampled plan is a different extraction profile by design:
      // the default policy refuses the reuse instead of pretending the
      // modes share a revision. (The page's text itself can be equal —
      // the profile, not the digest, is what always differs.)
      final strict = DurableAnnotations.resolve(anchor: anchor, targets: [sessionSnapshot]);
      expect(strict, isA<AnchorIncompatibleRevision>());
      expect((strict as AnchorIncompatibleRevision).differingFields, contains('textProfileId'));

      // The declared migration re-finds the unambiguous excerpt.
      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: [sessionSnapshot],
        policy: AnchorPolicy.explicitMigration,
      );

      final resolved = resolution as AnchorResolved;
      expect(resolved.verified, isFalse);
      expect(resolved.range.text, anchor.quote.exact);
    });

    test('source regions agree between the modes at the resolved position', () async {
      final session = await BookSession.open(bytes);
      addTearDown(session.dispose);
      final sessionStructure = (await session.loadPdfPageStructure(anchorPage))!;

      // The quote crosses source lines; the line holding its first
      // character maps into both canonical spaces, and both mappings
      // overlap the resolved ranges.
      (int, PdfMappedPosition)? covering;
      for (var line = 0; line < structure.sourceLines.length; line++) {
        final lineLength = structure.sourceLines[line].text.length;
        if (lineLength == 0) continue;
        final mapping = structure.mapSourceRange(
          PdfSourceRange(pageIndex: anchorPage, lineIndex: line, start: 0, end: lineLength),
        );
        if (mapping is! PdfPositionMapped) continue;
        if (mapping.position.offset <= quoteSpan.$1 && mapping.position.end > quoteSpan.$1) {
          covering = (line, mapping.position);
          break;
        }
      }
      expect(covering, isNotNull, reason: 'the quote must start inside a mapped source line');
      expect(covering!.$2.end, greaterThan(quoteSpan.$1));

      final sessionMapping = sessionStructure.mapSourceRange(
        PdfSourceRange(
          pageIndex: anchorPage,
          lineIndex: covering.$1,
          start: 0,
          end: structure.sourceLines[covering.$1].text.length,
        ),
      );
      expect(sessionMapping, isA<PdfPositionMapped>());
      final mapped = (sessionMapping as PdfPositionMapped).position;
      expect(
        sessionStructure.canonicalText.substring(mapped.offset, mapped.end),
        structure.sourceLines[covering.$1].text,
      );
    });

    test('an incompatible revision invalidates the index and migrates the anchor', () {
      // A host claiming a new revision of the same publication: the
      // serialized index refuses to reopen, and the anchor migrates
      // only through the declared policy.
      final claimedRevision = PublicationRevision(
        publicationId: identity.publicationId,
        sourceRevision: 'host:claim-v2',
        sourceEvidence: SourceEvidence.host,
      );

      final index = BookSearchIndex.empty(
        identity: SearchIndexIdentity(
          publicationId: identity.publicationId,
          sourceRevision: sourceRevision,
          sourceEvidence: SearchSourceEvidence.sha256,
        ),
        // The PDF persistence gate is A02's integration decision (its
        // default stays closed); this acceptance exercises the
        // identity-invalidation contract, so the index opts in.
        persistable: true,
      );
      indexAllSections(index);
      final payload = index.serialize();
      expect(
        () => BookSearchIndex.deserialize(
          payload,
          identity: SearchIndexIdentity(
            publicationId: identity.publicationId,
            sourceRevision: 'host:claim-v2',
            sourceEvidence: SearchSourceEvidence.host,
          ),
        ),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );

      final snapshot = structure.canonicalSnapshot(identity: identity);
      final anchor = DurableAnnotations.capture(
        snapshot: snapshot,
        start: quoteSpan.$1,
        end: quoteSpan.$2,
      );
      final claimedTargets = [structure.canonicalSnapshot(identity: claimedRevision)];

      expect(
        DurableAnnotations.resolve(anchor: anchor, targets: claimedTargets),
        isA<AnchorIncompatibleRevision>(),
      );

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: claimedTargets,
        policy: AnchorPolicy.explicitMigration,
      );
      final resolved = resolution as AnchorResolved;
      expect(resolved.verified, isFalse);
      expect(resolved.range.text, anchor.quote.exact);
    });
  });
}

/// A word-start run near the page's vertical middle, long enough to be
/// unique in practice: the unambiguous excerpt the acceptance resolves.
(int, int) _midPageQuote(final String text) {
  var start = text.length ~/ 3;
  while (start < text.length && !_isSpace(text.codeUnitAt(start))) {
    start++; // Finish the word under the target offset.
  }
  while (start < text.length && _isSpace(text.codeUnitAt(start))) {
    start++; // Take the next word's first character.
  }
  var end = start + 140;
  if (end >= text.length) {
    throw StateError('the corpus page carries too little mid-page text');
  }
  while (end < text.length && !_isSpace(text.codeUnitAt(end))) {
    end++;
  }

  return (start, end);
}

bool _isSpace(final int unit) => unit == 0x20 || (unit >= 0x09 && unit <= 0x0D);
