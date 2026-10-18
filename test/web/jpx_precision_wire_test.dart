@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

import '../tests/pdf/pdf_fixture_builder.dart';

// Committed precision fixtures (test/resources/pdf/jpeg2000/precision/,
// SHA-256 digests in its MANIFEST.md), inlined so the browser suite
// needs no HTTP fixtures:
//   synth-gray16-lossless.j2k, real-sycc8-420-lossless-odd-ffmpeg.jp2,
//   synth-sycc12-420-lossless-origin-tiles.jp2, synth-gray8-sub2x1-origin.j2k.
final Uint8List _gray16 = base64Decode(
  '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',
);

final Uint8List _sycc420Odd = base64Decode(
  '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'
  '5irY8yOB3sZicVQLIR17H//Z',
);

final Uint8List _sycc12OriginTiles = base64Decode(
  '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'
  'Cf/Z',
);

final Uint8List _gray8Sub2x1Origin = base64Decode(
  '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',
);

/// One browser golden: the PDF built around the codestream, the PNG
/// header the adapter must emit and the SHA-256 of the inflated IDAT
/// scanlines the VM produced for the same input (`dart test` on the
/// VM pins the same values through pdf_jpx_precision_test.dart's
/// contract checks; the deflate stream itself is not host-stable).
final class _Golden {
  const _Golden(
    this.name,
    this.bytes,
    this.width,
    this.height,
    this.components,
    this.bitDepth,
    this.sbit,
    this.rowsSha256,
  );

  final String name;
  final Uint8List bytes;
  final int width;
  final int height;
  final int components;
  final int bitDepth;
  final List<int>? sbit;
  final String rowsSha256;

  Uint8List pdf({final bool drawTwice = false}) => Uint8List.fromList(
    jpxImagePageFixture(
      bytes,
      width: width,
      height: height,
      components: components,
      drawTwice: drawTwice,
    ).build(),
  );
}

final List<_Golden> _goldens = <_Golden>[
  _Golden(
    'gray16-lossless',
    _gray16,
    64,
    48,
    1,
    16,
    null,
    '1044f0fd1daa6659f074bf7bf9300fb611b513d6e3ff10593543cb408d1a3df5',
  ),
  _Golden(
    'sycc8-420-odd-ffmpeg',
    _sycc420Odd,
    63,
    45,
    3,
    8,
    null,
    'ea504e841859b403a7d0803c98ef0399bfc918857a0dd6847690b1263cbe2f8c',
  ),
  _Golden('sycc12-420-origin-tiles', _sycc12OriginTiles, 63, 45, 3, 16, <int>[
    12,
    12,
    12,
  ], '3f4832988f99d2a2717461be6e5ae19d3d4b85a04d162d823519ee71e91af5ab'),
  _Golden(
    'gray8-sub2x1-origin',
    _gray8Sub2x1Origin,
    63,
    48,
    1,
    8,
    null,
    '0cd4c055858d1a2b4c6f968607540f474582505f4834904949fb1314adc32e70',
  ),
];

({int bitDepth, int colorType, List<int>? sbit, Uint8List rows}) _png(final Uint8List png) {
  final data = ByteData.sublistView(png);
  var cursor = 8;
  final idat = BytesBuilder(copy: false);
  var bitDepth = 0;
  var colorType = 0;
  List<int>? sbit;
  while (cursor + 8 <= png.length) {
    final length = data.getUint32(cursor);
    final type = String.fromCharCodes(png.sublist(cursor + 4, cursor + 8));
    final body = png.sublist(cursor + 8, cursor + 8 + length);
    if (type == 'IHDR') {
      bitDepth = body[8];
      colorType = body[9];
    } else if (type == 'sBIT') {
      sbit = body;
    } else if (type == 'IDAT') {
      idat.add(body);
    }
    cursor += 12 + length;
  }
  return (
    bitDepth: bitDepth,
    colorType: colorType,
    sbit: sbit,
    rows: Uint8List.fromList(const ZLibDecoder().decodeBytes(idat.toBytes())),
  );
}

Future<void> _expectRealWorker(final Uint8List bytes) async {
  final probe = await WorkerClient.instance.sessionOpenInWorker(bytes);
  expect(probe, isNotNull, reason: 'this integration test must exercise the real Web Worker');
  WorkerClient.instance.sessionDisposeInWorker(probe!.sessionId);
}

/// JPXDecode precision and subsampling inside the web worker: the
/// compiled JavaScript build must produce the pixels the VM produces
/// (16-bit planes, sYCC 4:2:0 with the odd-origin and fused-multiply
/// rules, replication upsampling) through the eager parse and through
/// two concurrent sessions.
void main() {
  setUp(() {
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  for (final golden in _goldens) {
    test('${golden.name}: the worker decodes to the VM-identical PNG samples', () {
      final book = Unseal.parse(golden.pdf()) as PdfBook;
      expect(book.files.images, hasLength(1));
      final image = book.files.images.single;
      expect(image.path, 'images/pdf-image-8.png');
      final png = _png(image.content);
      expect(png.bitDepth, golden.bitDepth);
      expect(png.colorType, golden.components == 3 ? 2 : 0);
      expect(png.sbit, golden.sbit);
      expect(sha256.convert(png.rows).toString(), golden.rowsSha256);
    });
  }

  test('two concurrent worker sessions serve the 16-bit and sYCC images on demand', () async {
    final gray = _goldens[0];
    final sycc = _goldens[2];
    final grayPdf = gray.pdf();
    final syccPdf = sycc.pdf();
    await _expectRealWorker(grayPdf);

    final sessions = await Future.wait(<Future<BookSession>>[
      BookSession.open(grayPdf),
      BookSession.open(syccPdf),
    ]);
    for (final session in sessions) {
      addTearDown(session.dispose);
    }
    final resources = await Future.wait(<Future<Uint8List?>>[
      sessions[0].loadResource('images/pdf-image-8.png'),
      sessions[1].loadResource('images/pdf-image-8.png'),
    ]);
    expect(resources[0], isNotNull);
    expect(resources[1], isNotNull);
    expect(sha256.convert(_png(resources[0]!).rows).toString(), gray.rowsSha256);
    expect(sha256.convert(_png(resources[1]!).rows).toString(), sycc.rowsSha256);
    expect(_png(resources[1]!).sbit, <int>[12, 12, 12]);
    // Sessions and the eager parse agree byte for byte on the same host.
    final eager = Unseal.parse(syccPdf) as PdfBook;
    expect(resources[1], eager.files.images.single.content);
    // A second request of the same path answers from the session cache
    // with the same bytes.
    expect(await sessions[1].loadResource('images/pdf-image-8.png'), resources[1]);
  });

  test('a repeated placement still extracts one 16-bit image in the worker', () {
    final book = Unseal.parse(_goldens[0].pdf(drawTwice: true)) as PdfBook;
    expect(book.files.images, hasLength(1));
    expect(book.pageTexts.single.images, hasLength(2));
    expect(_png(book.files.images.single.content).bitDepth, 16);
  });
}
