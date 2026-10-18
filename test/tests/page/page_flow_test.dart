import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/page_snapshot.dart';

/// The public PAGE flow: sidecar → host-confirmed snapshot → search and
/// index → region/polygon → anchor → reopen → the same occurrence.
void main() {
  final Uint8List kantFixture = File(
    'test/resources/page/kant-aufklaerung-1784-0017.xml',
  ).readAsBytesSync();
  final document = parsePageXmlDocument(kantFixture);

  // The host's target publication: a TXT book whose reading text is the
  // transcription the sidecar describes, one word per line in reading
  // order. Real corpus sidecar, derived target — the flow under test is
  // the binding chain, not OCR quality.
  final targetTextBuffer = StringBuffer();
  for (final region in document.page.regionsInReadingOrder()) {
    for (final line in region.lines) {
      for (final word in line.words) {
        final text = word.text?.text;
        if (text == null || text.isEmpty) continue;
        targetTextBuffer.writeln(text);
      }
    }
  }
  final Uint8List bookBytes = Uint8List.fromList(utf8.encode(targetTextBuffer.toString()));

  final identity = PublicationRevision(
    publicationId: 'gt:kant-aufklaerung-1784',
    sourceRevision: 'sha256:4a92747331018bdb11244a44854778b59757ed10c39913fa5bad67bf08f937cc',
    sourceEvidence: SourceEvidence.sha256,
  );

  Future<(DocumentBook book, CanonicalTextSnapshot snapshot, PageXmlSnapshotBinding binding)>
  open() async {
    final book = parseTxtBook(bookBytes, sourceName: 'kant-0017');
    final snapshot = DurableAnnotations.sectionSnapshot(book, sectionIndex: 0, identity: identity);
    final binding = bindPageToSnapshot(document: document, target: snapshot);

    return (book, snapshot, binding);
  }

  test('PAGE → snapshot → search → region/polygon → anchor → reopen', () async {
    final (book, snapshot, binding) = await open();
    expect(binding.wordsResolved, greaterThan(30), reason: 'the Kant page binds extensively');
    expect(binding.wordsMissing, lessThan(binding.wordsResolved));

    // A distinctive sidecar word: a long resolved word zone from the
    // binding itself, so the query is the sidecar's own reading.
    final lookup = binding.lookup!;
    final query = lookup.zones
        .where((zone) => zone.kind == SpatialZoneKind.word)
        .map((zone) => snapshot.text.substring(zone.textStart, zone.textEnd))
        .firstWhere((word) => word.length >= 6 && RegExp(r'^[A-Za-z]+$').hasMatch(word));
    final results = book.search(query, isCaseSensitive: true, isTolerant: false);
    expect(results.matches, isNotEmpty);
    final match = results.matches.first;
    expect(match.sectionIndex, 0);

    // The search hit lands inside a bound word zone; the zone's region
    // paints the native polygon's bounding box.
    final zone = lookup.wordAt(match.start);
    expect(zone, isNotNull, reason: 'the hit offset must sit inside a bound word');
    final regions = lookup.regionsOf([zone!]);
    expect(regions, hasLength(1));
    final regionZone = regions.single;
    final nativeRegion = document.page.regionsInReadingOrder().firstWhere(
      (region) => region.polygon.boundingRect == regionZone.rect,
    );
    expect(
      nativeRegion.polygon.points,
      isNotEmpty,
      reason: 'the native polygon stays on the document',
    );
    expect(snapshot.text.substring(zone.textStart, zone.textEnd), query);

    // The anchor captures the hit; encode → decode simulates
    // persistence, then the reopened book re-resolves the same
    // occurrence.
    final anchor = DurableAnnotations.capture(
      snapshot: snapshot,
      start: match.start,
      end: match.end,
    );
    final encoded = encodeAnchor(anchor);
    final persisted = decodeAnchor(encoded);

    final reopened = parseTxtBook(bookBytes, sourceName: 'kant-0017');
    final targets = DurableAnnotations.sectionSnapshots(reopened, identity: identity);
    final resolution = DurableAnnotations.resolve(anchor: persisted, targets: targets);
    expect(resolution, isA<AnchorResolved>());
    final resolved = resolution as AnchorResolved;
    expect(resolved.verified, isTrue);
    expect(resolved.range.snapshot.occurrence.sectionIndex, 0);
    expect(resolved.range.start, match.start);
    expect(resolved.range.end, match.end);
    // The resolved selection still addresses the same bound zone.
    expect(
      lookup.wordAt(resolved.range.start),
      zone,
      reason: 'reopening returns the identical occurrence',
    );
  });

  test('the inverted index hits the same bound zone', () async {
    final (book, snapshot, binding) = await open();
    final index = await BookSearchIndex.build(
      book,
      identity: SearchIndexIdentity(publicationId: identity.publicationId),
    );
    expect(index.coverage.indexedSections, 1);
    final query = binding.lookup!.zones
        .where((zone) => zone.kind == SpatialZoneKind.word)
        .map((zone) => snapshot.text.substring(zone.textStart, zone.textEnd))
        .firstWhere((word) => word.length >= 6 && RegExp(r'^[A-Za-z]+$').hasMatch(word));
    final hits = index.query(query);
    expect(hits.hits, isNotEmpty);
    final hit = hits.hits.first;
    expect(hit.sectionIndex, 0);

    final zone = binding.lookup!.wordAt(hit.start);
    expect(zone, isNotNull);
    expect(snapshot.text.substring(zone!.textStart, zone.textEnd), query);
    // The indexed hit and the scan hit describe the same occurrence.
    final scan = book.search(query, isCaseSensitive: true, isTolerant: false);
    expect(scan.matches.first.start, hit.start);
  });

  test('a changed origin or revision invalidates verified reuse', () async {
    final (_, snapshot, _) = await open();
    final anchor = DurableAnnotations.capture(snapshot: snapshot, start: 0, end: 10);
    // A destination under a different source revision cannot reuse the
    // anchor's identity; verified reuse refuses instead of guessing.
    final changedIdentity = PublicationRevision(
      publicationId: identity.publicationId,
      sourceRevision: 'sha256:${'a' * 64}',
      sourceEvidence: SourceEvidence.sha256,
    );
    final revisedBook = parseTxtBook(bookBytes, sourceName: 'kant-0017');
    final revisedTargets = DurableAnnotations.sectionSnapshots(
      revisedBook,
      identity: changedIdentity,
    );
    final resolution = DurableAnnotations.resolve(anchor: anchor, targets: revisedTargets);
    expect(resolution, isA<AnchorIncompatibleRevision>());

    // The PAGE binding reports the same contract: its recorded identity
    // tuple no longer matches a changed target.
    final binding = bindPageToSnapshot(document: document, target: snapshot);
    final changedSnapshot = pageSnapshot('${snapshot.text}x');
    expect(binding.target.sameIdentity(changedSnapshot), isFalse);
    expect(binding.target.textRevision == changedSnapshot.textRevision, isFalse);
  });
}
