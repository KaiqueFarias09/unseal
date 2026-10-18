import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/tiff/tiff_container.dart';
import 'package:unseal/src/features/tiff/tiff_limits.dart';
import 'package:unseal/src/features/tiff/tiff_page_decoder.dart';
import 'package:unseal/unseal.dart';

import '../../support/tiff_tiled_fixture.dart';

void main() {
  test('CCITT current and reference rows are reserved before decoding', () {
    final bytes = buildSyntheticTiff(
      data: Uint8List.fromList([0x80]),
      pages: (offset) => [
        [
          SyntheticTiffTag.long(256, 64),
          SyntheticTiffTag.long(257, 1),
          SyntheticTiffTag.short(258, 1),
          SyntheticTiffTag.short(259, 4),
          SyntheticTiffTag.short(262, 0),
          SyntheticTiffTag.short(277, 1),
          SyntheticTiffTag.long(322, 64),
          SyntheticTiffTag.long(323, 1),
          SyntheticTiffTag.long(324, offset),
          SyntheticTiffTag.long(325, 1),
        ],
      ],
    );
    final container = TiffContainer(bytes);
    final budget = TiffDecodeBudget()
      ..reserve(pixels: 0, rasterBytes: tiffMaxDecodedRasterBytesPerBook - 10000);
    expect(
      () => decodeTiffPage(container, container.pageDirectories.single, budget: budget),
      throwsA(isA<TiffException>().having((e) => e.message, 'message', contains('scratch'))),
    );
    expect(budget.scratchBytes, 0);
    expect(budget.workBytes, 0, reason: 'the row-state refusal precedes codec work');
  });

  test('native observer sees 16-bit post-predictor samples before cropping and quantization', () {
    final data = Uint8List(8);
    final values = ByteData.sublistView(data);
    for (final (index, value) in [0x1201, 0x0002, 0x3456, 0x0004].indexed) {
      values.setUint16(index * 2, value, Endian.big);
    }
    final bytes = buildSyntheticTiff(
      data: data,
      endian: Endian.big,
      pages: (offset) => [
        [
          SyntheticTiffTag.long(256, 1),
          SyntheticTiffTag.long(257, 1),
          SyntheticTiffTag.short(258, 16),
          SyntheticTiffTag.short(259, 1),
          SyntheticTiffTag.short(262, 1),
          SyntheticTiffTag.short(277, 1),
          SyntheticTiffTag.short(317, 2),
          SyntheticTiffTag.long(322, 2),
          SyntheticTiffTag.long(323, 2),
          SyntheticTiffTag.long(324, offset),
          SyntheticTiffTag.long(325, data.length),
        ],
      ],
    );
    final container = TiffContainer(bytes);
    var observations = 0;
    final image = decodeTiffPage(
      container,
      container.pageDirectories.single,
      budget: TiffDecodeBudget(),
      onDecodedSegment: (segment) {
        observations++;
        expect(
          (segment.rowStart, segment.columnStart, segment.width, segment.height),
          (0, 0, 1, 1),
        );
        expect((segment.rowBytes, segment.bits, segment.samplesPerPixel), (4, 16, 1));
        final observed = ByteData.sublistView(segment.bytes);
        expect(
          [for (var index = 0; index < 4; index++) observed.getUint16(index * 2, segment.endian)],
          [0x1201, 0x1203, 0x3456, 0x345a],
        );
        expect(() => segment.bytes[0] = 0, throwsUnsupportedError);
      },
    );
    expect(observations, 1);
    expect(image.bmp![54], 0x12, reason: 'display keeps the high byte, observation keeps both');
    expect(data, [
      0x12,
      0x01,
      0,
      2,
      0x34,
      0x56,
      0,
      4,
    ], reason: 'predictor never mutates its source');
  });

  test('vertical orientation swaps complete rows and preserves an odd middle row', () {
    final data = Uint8List.fromList([10, 20, 30, 40, 50, 60]);
    final bytes = buildSyntheticTiff(
      data: data,
      pages: (offset) => [
        [
          SyntheticTiffTag.long(256, 2),
          SyntheticTiffTag.long(257, 3),
          SyntheticTiffTag.short(258, 8),
          SyntheticTiffTag.short(259, 1),
          SyntheticTiffTag.short(262, 1),
          SyntheticTiffTag.short(274, 4),
          SyntheticTiffTag.short(277, 1),
          SyntheticTiffTag.long(278, 3),
          SyntheticTiffTag.long(273, offset),
          SyntheticTiffTag.long(279, data.length),
        ],
      ],
    );
    final page = parseTiffBook(bytes).pages.single;
    final bmp = page.image.content;
    expect(
      [
        for (var y = 0; y < 3; y++)
          for (var x = 0; x < 2; x++) bmp[54 + (2 - y) * 8 + x * 3],
      ],
      [50, 60, 30, 40, 10, 20],
    );
  });
}
