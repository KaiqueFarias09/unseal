import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/annotations/durable/anchor_resolution.dart';
import 'package:unseal/src/features/annotations/durable/durable_annotations.dart';
import 'package:unseal/src/features/djvu/djvu_exception.dart';
import 'package:unseal/src/features/djvu/djvu_page_structure.dart';
import 'package:unseal/src/features/djvu/djvu_text.dart';
import 'package:unseal/src/features/djvu/parse_djvu_book.dart';
import 'package:unseal/src/foundation/spatial/spatial_text_page.dart';
import 'package:unseal/src/foundation/spatial/spatial_text_zone.dart';
import 'package:unseal/src/foundation/spatial/spatial_unit.dart';
import 'package:unseal/src/foundation/text/canonical_text_snapshot.dart';
import 'package:unseal/src/foundation/text/publication_revision.dart';
import 'package:unseal/src/foundation/text/text_profile.dart';

Uint8List _int24(final int value) => Uint8List.fromList(<int>[
  (value >> 16) & 255,
  (value >> 8) & 255,
  value & 255,
]);

Uint8List _rawText(final String text, {final List<int> zones = const []}) => Uint8List.fromList([
  ..._int24(utf8.encode(text).length),
  ...utf8.encode(text),
  1,
  ...zones,
]);

/// One 17-byte zone record; coordinates are stored bias-encoded and the
/// text start is the delta the reference decoder accumulates.
List<int> _zone({
  required final int type,
  final int x = 0x8000,
  final int y = 0x8000,
  final int w = 0x8000,
  final int h = 0x8000,
  final int textStart = 0x8000,
  final int textLength = 0,
  final int children = 0,
}) =>
    [
      type,
      (x >> 8) & 255,
      x & 255,
      (y >> 8) & 255,
      y & 255,
      (w >> 8) & 255,
      w & 255,
      (h >> 8) & 255,
      h & 255,
      (textStart >> 8) & 255,
      textStart & 255,
      (textLength >> 16) & 255,
      (textLength >> 8) & 255,
      textLength & 255,
      (children >> 16) & 255,
      (children >> 8) & 255,
      children & 255,
    ];

PublicationRevision _identity(final Uint8List bytes) => PublicationRevision(
  publicationId: 'test:spatial-djvu',
  sourceRevision: 'sha256:${sha256.convert(bytes).toString()}',
  sourceEvidence: SourceEvidence.sha256,
);

void main() {
  final goody = File('test/resources/djvu/goody-twoshoes.djvu').readAsBytesSync();

  group('TXTz zone tree decoding', () {
    test('decodes the corpus page tree with reference-exact coordinates', () {
      // Page 1 of goody-twoshoes, verified against djvused print-txt
      // (DjVuLibre 3.5.29): the page zone and its first word.
      final book = parseDjvuBook(goody);
      final chunk = book.pages[0].textChunk!;
      final root = chunk.root!;
      expect(root.type, djvuZoneTypePage);
      expect(<int>[root.xmin, root.ymin, root.xmax, root.ymax], <int>[1216, 423, 2152, 639]);
      final word = root.children[0].children[0].children[0].children[0].children[0];
      expect(word.type, djvuZoneTypeWord);
      expect(<int>[word.xmin, word.ymin, word.xmax, word.ymax], <int>[1216, 423, 1256, 551]);
      expect(chunk.text.substring(word.utf16Start, word.utf16End), '< ');
    });

    test('accumulates sibling text deltas and maps UTF-8 bytes to UTF-16', () {
      // 'aé𝄞b' is 8 UTF-8 bytes and 5 UTF-16 code units: the second
      // word's range must land on code-unit boundaries of the astral
      // character.
      const text = 'aé𝄞b';
      final chunk = decodeDjvuTextChunkRaw(
        _rawText(
          text,
          zones: <int>[
            ..._zone(
              type: djvuZoneTypePage,
              x: 0x8000,
              y: 0x8000,
              w: 100 + 0x8000,
              h: 100 + 0x8000,
              textLength: 8,
              children: 2,
            ),
            ..._zone(type: djvuZoneTypeWord, w: 0x8000 + 8, h: 0x8000 + 8, textLength: 3),
            ..._zone(type: djvuZoneTypeWord, w: 0x8000 + 8, h: 0x8000 + 8, textLength: 5),
          ],
        ),
      );
      final words = chunk.root!.children;
      expect(chunk.text.substring(words[0].utf16Start, words[0].utf16End), 'aé');
      expect(chunk.text.substring(words[1].utf16Start, words[1].utf16End), '𝄞b');
      expect(words[1].utf16Start, 2);
      expect(words[1].utf16End, 5);
    });

    test('rejects a range that splits a multi-byte character', () {
      expect(
        () => decodeDjvuTextChunkRaw(
          _rawText(
            'aé',
            zones: <int>[
              ..._zone(type: djvuZoneTypePage, textLength: 3, children: 1),
              ..._zone(type: djvuZoneTypeWord, textStart: 0x8000, textLength: 2),
            ],
          ),
        ),
        throwsA(isA<DjvuException>()),
      );
    });

    test('rejects hostile records with typed failures', () {
      // Empty rectangle.
      expect(
        () => decodeDjvuTextChunkRaw(
          _rawText(
            'ab',
            zones: <int>[..._zone(type: djvuZoneTypePage, w: 0x8000, textLength: 2)],
          ),
        ),
        throwsA(isA<DjvuException>()),
      );
      // Zone type outside 1..7.
      expect(
        () => decodeDjvuTextChunkRaw(
          _rawText('ab', zones: <int>[..._zone(type: 8, textLength: 2)]),
        ),
        throwsA(isA<DjvuException>()),
      );
      // Text range beyond the page text.
      expect(
        () => decodeDjvuTextChunkRaw(
          _rawText('ab', zones: <int>[..._zone(type: djvuZoneTypePage, textLength: 3)]),
        ),
        throwsA(isA<DjvuException>()),
      );
      // Child count exceeding the record budget.
      expect(
        () => decodeDjvuTextChunkRaw(
          _rawText(
            'ab',
            zones: <int>[..._zone(type: djvuZoneTypePage, textLength: 2, children: 3)],
          ),
        ),
        throwsA(isA<DjvuException>()),
      );
    });

    test('bounds zone nesting depth', () {
      // 33 nested records of the same type exceed the depth limit.
      List<int> chain(final int depth) => <int>[
        for (var i = 0; i < depth; i++)
          ..._zone(
            type: djvuZoneTypeRegion,
            w: 0x8000 + 10,
            h: 0x8000 + 10,
            children: i == depth - 1 ? 0 : 1,
          ),
      ];
      expect(
        () => decodeDjvuTextChunkRaw(_rawText('', zones: chain(33))),
        throwsA(isA<DjvuException>()),
      );
      final chunk = decodeDjvuTextChunkRaw(_rawText('', zones: chain(32)));
      expect(chunk.zoneCount, 32);
    });
  });

  group('DjvuPageStructure', () {
    late DjvuPageStructure structure;

    setUp(() {
      final book = parseDjvuBook(goody);
      structure = book.pageStructureAt(0)!;
    });

    test('projects the shared region/line/word levels top-left', () {
      final page = structure.spatialPage!;
      expect(page.unit, SpatialUnit.pixel);
      expect(page.width, structure.width.toDouble());
      expect(page.height, structure.height.toDouble());
      final word = page.zones.firstWhere((final z) => z.kind == SpatialZoneKind.word);
      // The native word spans ymax 551; top-left y mirrors it.
      expect(word.rect.y, structure.height - 551);
      expect(word.rect.x, 1216);
      expect(page.provenance.origin, SpatialTextOrigin.native);
      expect(page.provenance.hasConfidence, isFalse);
    });

    test('lookup resolves the word, line and region holding an offset', () {
      final page = structure.spatialPage!;
      final lookup = structure.lookup!;
      final word = page.zones.firstWhere((final z) => z.kind == SpatialZoneKind.word);
      expect(lookup.wordAt(word.textStart), word);
      expect(lookup.lineAt(word.textStart)?.kind, SpatialZoneKind.line);
      expect(lookup.regionAt(word.textStart)?.kind, SpatialZoneKind.region);
      // The region ancestor of the word is the same region the offset
      // lands in.
      expect(SpatialTextPage.ancestorOf(page.zones, page.zones.indexOf(word), SpatialZoneKind.region), lookup.regionAt(word.textStart));
      // Offsets outside every word have no word zone.
      expect(lookup.wordAt(structure.canonicalText.length - 1), isNot(equals(word)));
    });

    test('snapshot binds the canonical text under the hidden-text profile', () {
      final snapshot = structure.snapshot(identity: _identity(goody));
      expect(snapshot.text, structure.canonicalText);
      expect(snapshot.profile.sameProfile(djvuHiddenTextProfile), isTrue);
      expect(snapshot.identity.sourceEvidence, SourceEvidence.sha256);
      expect(snapshot.occurrence.sectionIndex, 0);
      expect(snapshot.occurrence.resourcePath, 'text/page-1.html');
      expect(snapshot.isExportable, isTrue);
    });

    test('anchors capture and reuse through the snapshot identity', () {
      final identity = _identity(goody);
      final snapshot = structure.snapshot(identity: identity);
      final word = structure.spatialPage!.zones.firstWhere(
        (final z) => z.kind == SpatialZoneKind.word,
      );
      final anchor = DurableAnnotations.capture(
        snapshot: snapshot,
        start: word.textStart,
        end: word.textEnd,
      );

      // A fresh parse of the same bytes re-mints the same snapshot and
      // resolves the anchor as verified identity reuse.
      final reopened = parseDjvuBook(goody).pageStructureAt(0)!.snapshot(identity: identity);
      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: <CanonicalTextSnapshot>[reopened],
      );
      expect(resolution, isA<AnchorResolved>());
      final resolved = resolution as AnchorResolved;
      expect(resolved.verified, isTrue);
      expect(resolved.range.start, word.textStart);
    });

    test('a different profile invalidates reuse instead of resolving', () {
      final identity = _identity(goody);
      final snapshot = structure.snapshot(identity: identity);
      final word = structure.spatialPage!.zones.firstWhere(
        (final z) => z.kind == SpatialZoneKind.word,
      );
      final anchor = DurableAnnotations.capture(
        snapshot: snapshot,
        start: word.textStart,
        end: word.textEnd,
      );

      // The same identity but a foreign extraction profile is a different
      // text revision by construction: reuse is incompatible, not fuzzy.
      final foreign = CanonicalTextSnapshot(
        identity: identity,
        occurrence: snapshot.occurrence,
        profile: TextProfile.of(
          algorithm: 'test.foreign',
          options: const <String, String>{},
          planRevision: snapshot.profile.planRevision,
        ),
        text: snapshot.text,
      );
      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: <CanonicalTextSnapshot>[foreign],
      );
      expect(resolution, isA<AnchorIncompatibleRevision>());
    });

    test('repeated quotes resolve through context evidence, not position luck', () {
      // A page whose text repeats a word: an anchor that lost its
      // revision resolves by its context to the recorded occurrence,
      // unverified by identity, and the second occurrence's anchor stays
      // on the second occurrence.
      final repeated = decodeDjvuTextChunkRaw(_rawText('idea idea', zones: <int>[]));
      final structure = DjvuPageStructure(
        pageIndex: 0,
        pageCount: 1,
        width: 100,
        height: 100,
        dpi: 300,
        rotation: 0,
        chunk: repeated,
        readingOrderPaths: const <(String, bool)>[('text/page-1.html', true)],
      );
      final identity = PublicationRevision(publicationId: 'test:repeated');
      final revised = PublicationRevision(publicationId: 'test:repeated', editionId: 'v2');
      for (final (start, end) in const <(int, int)>[(0, 4), (5, 9)]) {
        final anchor = DurableAnnotations.capture(
          snapshot: structure.snapshot(identity: identity),
          start: start,
          end: end,
        );
        final resolution = DurableAnnotations.resolve(
          anchor: anchor,
          targets: <CanonicalTextSnapshot>[structure.snapshot(identity: revised)],
          policy: AnchorPolicy.contextRecovery,
        );
        expect(resolution, isA<AnchorResolved>());
        final resolved = resolution as AnchorResolved;
        expect(resolved.verified, isFalse);
        expect(resolved.range.start, start);
        expect(resolved.range.end, end);
      }
    });
  });
}
