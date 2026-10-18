import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// The public hOCR flow: sidecar → host-confirmed snapshot → search and
/// index → zone lookup → durable anchor → reopen → the same occurrence.
///
/// The sidecar is the committed Tesseract 5.5.3 run over the licensed
/// phototest image; the target book is a TXT whose reading text is the
/// sidecar's own transcription, one word per line. The flow under test is
/// the binding chain, not OCR quality.
void main() {
  final Uint8List fixture = File('test/resources/hocr/tesseract/phototest.hocr').readAsBytesSync();
  final document = parseHocrDocument(fixture);
  final targetText = StringBuffer();
  for (final line in document.pages.single.lines) {
    for (final word in line.words) {
      if (word.text.trim().isEmpty) continue;
      targetText.writeln(word.text);
    }
  }
  final Uint8List bookBytes = Uint8List.fromList(utf8.encode(targetText.toString()));

  final identity = PublicationRevision(
    publicationId: 'tesseract:phototest',
    sourceRevision: 'sha256:d2241a1eb6d6cd2eb6544b8e228c2862c852b7467d16ed636caa32179b780692',
    sourceEvidence: SourceEvidence.sha256,
  );

  HocrSnapshotBinding open() {
    final book = parseTxtBook(bookBytes, sourceName: 'phototest-transcription');
    final snapshot = DurableAnnotations.sectionSnapshot(book, sectionIndex: 0, identity: identity);
    final binding = bindHocrToSnapshot(document: document, target: snapshot);

    return binding;
  }

  test('hOCR → snapshot → search → zone → anchor → reopen', () {
    final binding = open();
    expect(binding.pages.single.provenance.softwareName, 'tesseract 5.5.3');
    expect(binding.wordsMissing, 0);
    // Every word of the transcription finds its line; words the text
    // repeats ('a', 'of', ...) report ambiguity, never a false unique.
    expect(binding.wordsResolved + binding.wordsAmbiguous, 60);
    expect(binding.wordsAmbiguous, greaterThan(0));

    final lookup = binding.lookups.single;
    final snapshot = binding.target;
    final query = lookup.zones
        .where((final zone) => zone.kind == SpatialZoneKind.word)
        .map((final zone) => snapshot.text.substring(zone.textStart, zone.textEnd))
        .firstWhere((final word) => word.length >= 6 && RegExp(r'^[A-Za-z]+$').hasMatch(word));
    final book = parseTxtBook(bookBytes, sourceName: 'phototest-transcription');
    final results = book.search(query, isCaseSensitive: true, isTolerant: false);
    expect(results.matches, isNotEmpty);
    final match = results.matches.first;
    expect(match.sectionIndex, 0);

    // The hit lands inside a bound word zone; its region paints the
    // declared box.
    final zone = lookup.wordAt(match.start);
    expect(zone, isNotNull, reason: 'the hit offset must sit inside a bound word');
    final regions = lookup.regionsOf([zone!]);
    expect(regions, hasLength(1));
    // The region is the word's nearest boxed ancestor: its paragraph.
    expect(binding.document.pages.single.frame!.rect.contains(regions.single.rect), isTrue);
    expect(snapshot.text.substring(zone.textStart, zone.textEnd), query);

    // The anchor captures the hit; encode → decode simulates persistence,
    // then the reopened book re-resolves the same occurrence.
    final anchor = DurableAnnotations.capture(
      snapshot: snapshot,
      start: match.start,
      end: match.end,
    );
    final persisted = decodeAnchor(encodeAnchor(anchor));

    final reopened = parseTxtBook(bookBytes, sourceName: 'phototest-transcription');
    final targets = DurableAnnotations.sectionSnapshots(reopened, identity: identity);
    final resolution = DurableAnnotations.resolve(anchor: persisted, targets: targets);
    expect(resolution, isA<AnchorResolved>());
    final resolved = resolution as AnchorResolved;
    expect(resolved.verified, isTrue);
    expect(resolved.range.start, match.start);
    expect(resolved.range.end, match.end);
    expect(
      lookup.wordAt(resolved.range.start),
      zone,
      reason: 'reopening returns the identical occurrence',
    );
  });

  test('the inverted index hits the same bound zone', () async {
    final binding = open();
    final book = parseTxtBook(bookBytes, sourceName: 'phototest-transcription');
    final index = await BookSearchIndex.build(
      book,
      identity: SearchIndexIdentity(publicationId: identity.publicationId),
    );
    expect(index.coverage.indexedSections, 1);
    final snapshot = binding.target;
    final query = binding.lookups.single.zones
        .where((final zone) => zone.kind == SpatialZoneKind.word)
        .map((final zone) => snapshot.text.substring(zone.textStart, zone.textEnd))
        .firstWhere((final word) => word.length >= 6 && RegExp(r'^[A-Za-z]+$').hasMatch(word));
    final hits = index.query(query);
    expect(hits.hits, isNotEmpty);
    final zone = binding.lookups.single.wordAt(hits.hits.first.start);
    expect(zone, isNotNull);
    expect(snapshot.text.substring(zone!.textStart, zone.textEnd), query);
  });

  test('a changed origin or revision invalidates verified reuse', () {
    final binding = open();
    final snapshot = binding.target;
    final anchor = DurableAnnotations.capture(snapshot: snapshot, start: 0, end: 10);
    final changedIdentity = PublicationRevision(
      publicationId: identity.publicationId,
      sourceRevision: 'sha256:${'a' * 64}',
      sourceEvidence: SourceEvidence.sha256,
    );
    final revisedBook = parseTxtBook(bookBytes, sourceName: 'phototest-transcription');
    final resolution = DurableAnnotations.resolve(
      anchor: anchor,
      targets: DurableAnnotations.sectionSnapshots(revisedBook, identity: changedIdentity),
    );
    expect(resolution, isA<AnchorIncompatibleRevision>());
    expect(
      binding.target.sameIdentity(
        CanonicalTextSnapshot(
          identity: binding.targetIdentity,
          occurrence: binding.targetOccurrence,
          profile: binding.targetProfile,
          text: '${snapshot.text} changed',
        ),
      ),
      isFalse,
    );
  });
}
