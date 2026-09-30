import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/djvu/djvu_outline.dart';
import 'package:unseal/src/features/djvu/djvu_text.dart';
import 'package:unseal/unseal.dart';

import '../../support/djvu_fixture.dart';

Uint8List _rawText(final String text, {final int version = 1, final List<int> zones = const []}) =>
    Uint8List.fromList(<int>[
      ..._int24(utf8.encode(text).length),
      ...utf8.encode(text),
      version,
      ...zones,
    ]);

List<int> _int24(final int value) => <int>[value >> 16 & 255, value >> 8 & 255, value & 255];

void main() {
  final cyrillic = File('test/resources/djvu/cyrillic.djvu').readAsBytesSync();
  final links = File('test/resources/djvu/links.djvu').readAsBytesSync();
  final navmFgbz = File('test/resources/djvu/navm-fgbz.djvu').readAsBytesSync();

  group('TXTz grammar', () {
    test('decodes Cyrillic text and counts zones from the corpus page', () {
      final chunk = decodeDjvuTextChunk(djvuCorpusChunk(cyrillic, 'TXTz'));
      expect(chunk.text, startsWith('(ЩУ И МШИ \nРУКОВОДСТВО ДЛЯ УЧИТЕЛЕЙ \n'));
      expect(chunk.text, contains('ТВЕРЬ. \n'));
      expect(chunk.zoneCount, greaterThan(0));
    });

    test('renders page-zone NUL separators as LF plus form feed', () {
      final chunk = decodeDjvuTextChunkRaw(_rawText('first\x00second'));
      expect(chunk.text, 'first\n\x0Csecond');
    });

    test('rejects truncated, misaligned, and wrong-version payloads', () {
      expect(
        () => decodeDjvuTextChunkRaw(Uint8List.fromList(<int>[0, 0])),
        throwsA(isA<DjvuException>()),
      );
      expect(
        () => decodeDjvuTextChunkRaw(_rawText('abc', version: 2)),
        throwsA(isA<DjvuException>()),
      );
      expect(
        () => decodeDjvuTextChunkRaw(
          Uint8List.fromList(<int>[..._int24(3), ...ascii.encode('abc'), 1, 0, 1]),
        ),
        throwsA(isA<DjvuException>()),
      );
      // Declared text length beyond the payload is truncated.
      expect(
        () =>
            decodeDjvuTextChunkRaw(Uint8List.fromList(<int>[0, 0, 99, ...ascii.encode('abc'), 1])),
        throwsA(isA<DjvuException>()),
      );
    });

    test('rejects text that is not valid UTF-8', () {
      final raw = Uint8List.fromList(<int>[..._int24(2), 0xFF, 0xFE, 1]);
      expect(() => decodeDjvuTextChunkRaw(raw), throwsA(isA<DjvuException>()));
    });
  });

  group('NAVM records', () {
    test('decodes the two bookmark corpus links', () {
      final points = decodeDjvuNavm(djvuCorpusChunk(links, 'NAVM'));
      expect(points, hasLength(2));
      expect(points[0].label, 'Relative Link');
      expect(points[0].content, 'colorbook.djvu');
      expect(points[1].label, 'Absolute Link');
      expect(points[1].content, 'https://djvu.js.org/assets/djvu_examples/DjVu3Spec.djvu');
      expect(points[0].classAttribute, 'bookmark');
      expect(points[0].subNavPoints, isEmpty);
    });

    test('decodes nested corpus bookmarks with claimed children', () {
      final points = decodeDjvuNavm(djvuCorpusChunk(navmFgbz, 'NAVM'));
      expect(points.map((final point) => point.label), <String>[
        'Links',
        'Ink, Rectangles, Ellipses, Lines',
        'Stamps',
        'Last Page',
      ]);
      final stamps = points[2];
      expect(stamps.content, '#3');
      expect(stamps.subNavPoints.map((final point) => point.label), <String>[
        'Stamps - Faces',
        'Stamps - Pointers',
      ]);
    });

    test('rejects child counts that exceed the bookmark pool', () {
      // One declared bookmark whose record claims two children: the tree can
      // never complete, which is a typed failure rather than a silent crop.
      final raw = Uint8List.fromList(<int>[
        0, 1, // count = 1
        2, ..._int24(4), ...ascii.encode('root'), ..._int24(0), // claims 2
      ]);
      expect(() => decodeDjvuNavmRecords(raw), throwsA(isA<DjvuException>()));
    });

    test('rejects records that run past the decompressed payload', () {
      final raw = Uint8List.fromList(<int>[
        0, 2, // count = 2, only one record follows
        0, ..._int24(4), ...ascii.encode('only'), ..._int24(0),
      ]);
      expect(() => decodeDjvuNavmRecords(raw), throwsA(isA<DjvuException>()));
    });

    test('rejects description and URL lengths beyond the payload', () {
      final raw = Uint8List.fromList(<int>[0, 1, 0, ..._int24(99), ..._int24(0)]);
      expect(() => decodeDjvuNavmRecords(raw), throwsA(isA<DjvuException>()));
      final raw2 = Uint8List.fromList(<int>[
        0,
        1,
        0,
        ..._int24(2),
        ...ascii.encode('ab'),
        ..._int24(99),
      ]);
      expect(() => decodeDjvuNavmRecords(raw2), throwsA(isA<DjvuException>()));
    });
  });
}
