import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

// PR04: the hostile half of PDF-over-source. Every contract violation a
// host can produce, every broken-structure case in the supported
// subset, and the allocation caps — all refused typed, with recovery
// cases staying byte-parity with the eager parse.
const dickensPdf = 'test/resources/pdf/dickens-sample.pdf';

Uint8List _bytes(final String path) => Uint8List.fromList(File(path).readAsBytesSync());

/// A source with sequence-addressed fault injection: the Nth read can
/// come back short, long, throw, or observe a flipped revision.
final class FaultySource implements UnsealByteSource {
  FaultySource(this.bytes, {this.revision});

  final Uint8List bytes;
  @override
  String? revision;
  var _closed = false;
  var _reads = 0;
  int? shortOn;
  int? longOn;
  int? throwOn;
  int? flipOn;

  bool get closed => _closed;

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    if (_closed) throw const ByteSourceClosedException();
    final sequence = _reads++;
    if (flipOn != null && sequence >= flipOn!) {
      revision = 'flipped-${revision ?? 'null'}';
    }
    if (throwOn == sequence) throw StateError('host transport failure');
    final slice = Uint8List.sublistView(
      bytes,
      offset,
      offset + (longOn == sequence ? count + 1 : count),
    );
    if (shortOn == sequence) return Uint8List.sublistView(bytes, offset, offset + count - 1);

    return slice;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

/// Builds a minimal but real single-page PDF: classic xref table, one
/// content stream (flate), one font, trailer with /Root. [prevSelf]
/// makes the trailer's /Prev point at its own xref — the cyclic chain.
Uint8List _buildSyntheticPdf({required final List<int> streamBytes, final bool prevSelf = false}) {
  final objects = <Uint8List>[
    // 1: catalog
    convert.ascii.encode('<< /Type /Catalog /Pages 2 0 R >>'),
    // 2: pages
    convert.ascii.encode('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    // 3: page
    convert.ascii.encode(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    ),
    // 4: the content stream
    Uint8List.fromList(<int>[
      ...convert.ascii.encode('<< /Length ${streamBytes.length} /Filter /FlateDecode >>\nstream\n'),
      ...streamBytes,
      ...convert.ascii.encode('\nendstream'),
    ]),
    // 5: font
    convert.ascii.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
  ];

  final body = BytesBuilder();
  body.add(convert.ascii.encode('%PDF-1.4\n'));
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(body.length);
    body.add(convert.ascii.encode('${i + 1} 0 obj\n'));
    body.add(objects[i]);
    body.add(convert.ascii.encode('\nendobj\n'));
  }

  final xrefStart = body.length;
  final xref = BytesBuilder();
  xref.add(convert.ascii.encode('xref\n0 ${objects.length + 1}\n'));
  xref.add(convert.ascii.encode('0000000000 65535 f \n'));
  for (final offset in offsets) {
    xref.add(convert.ascii.encode('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  final prev = prevSelf ? '$xrefStart' : '';
  xref.add(
    convert.ascii.encode(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R'
      '${prevSelf ? ' /Prev $prev' : ''} >>\n',
    ),
  );
  body.add(xref.toBytes());
  body.add(convert.ascii.encode('startxref\n$xrefStart\n%%EOF\n'));

  return body.toBytes();
}

Uint8List _flate(final String text) =>
    Uint8List.fromList(ZLibCodec().encode(convert.utf8.encode(text)));

void main() {
  group('host-source contract violations are typed (PR04)', () {
    test('a short answer fails the open with ByteSourceShortReadException', () async {
      final source = FaultySource(_bytes(dickensPdf))..shortOn = 2;
      await expectLater(
        BookSession.openSource(source),
        throwsA(isA<ByteSourceShortReadException>()),
      );
    });

    test('a long answer fails with ByteSourceLongReadException', () async {
      final source = FaultySource(_bytes(dickensPdf))..longOn = 1;
      await expectLater(
        BookSession.openSource(source),
        throwsA(isA<ByteSourceLongReadException>()),
      );
    });

    test('a host failure surfaces as ByteSourceReadException', () async {
      final source = FaultySource(_bytes(dickensPdf))..throwOn = 3;
      await expectLater(BookSession.openSource(source), throwsA(isA<ByteSourceReadException>()));
    });

    test('a revision flipped mid-open fails with ByteSourceRevisionChangedException', () async {
      final source = FaultySource(_bytes(dickensPdf), revision: 'c01:rev-1')..flipOn = 2;
      await expectLater(
        BookSession.openSource(source),
        throwsA(isA<ByteSourceRevisionChangedException>()),
      );
    });

    test('a revision flipped under an open session fails later reads typed', () async {
      final source = FaultySource(_bytes(dickensPdf), revision: 'c01:rev-1');
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      // loadBytesRange always rides the gate, cache or not.
      expect(await session.loadBytesRange(0, 64), isNotNull);
      source.flipOn = 0; // flip on the next read
      await expectLater(
        session.loadBytesRange(0, 64),
        throwsA(isA<ByteSourceRevisionChangedException>()),
      );

      // A revision flip the host reverts keeps the session usable.
      source.flipOn = null;
      source.revision = 'c01:rev-1';
      expect(await session.loadBytesRange(0, 64), isNotNull);
    });
  });

  group('broken structures keep the eager parse semantics (PR04)', () {
    test('a bogus startxref recovers by scan, byte-parity with eager', () async {
      final raw = _bytes(dickensPdf);
      final broken = Uint8List.fromList(raw);
      final markerAt = convert.latin1.decode(broken).lastIndexOf('startxref');
      expect(markerAt, greaterThan(0));
      final at = markerAt + 'startxref'.length + 1;
      // Overwrite the offset digits with a valid-but-wrong number.
      final bogus = convert.ascii.encode('999999');
      var end = at;
      while (end < broken.length && broken[end] >= 0x30 && broken[end] <= 0x39) {
        end++;
      }
      broken.setRange(at, end, bogus);

      final eager = Unseal.parse(raw) as PdfBook;
      final session = await BookSession.openSource(FaultySource(broken));
      addTearDown(session.dispose);

      final text = await session.loadDocumentText('page_1.html');
      expect(text, eager.pageTexts[0].text);
    });

    test('a cyclic /Prev chain terminates and stays parity with eager', () async {
      final synthetic = _buildSyntheticPdf(
        streamBytes: _flate('BT /F1 24 Tf 72 720 Td (cyclic trailer chain) Tj ET'),
        prevSelf: true,
      );

      final eager = Unseal.parse(synthetic) as PdfBook;
      final session = await BookSession.openSource(FaultySource(synthetic));
      addTearDown(session.dispose);

      expect((session.book as PdfBook).pageCount, eager.pageCount);
      final text = await session.loadDocumentText('page_1.html');
      expect(
        text,
        contains('cyclic trailer chain'),
        reason: 'real canonical text, not a vacuous empty match',
      );
      expect(text, eager.pageTexts[0].text);
    });
  });

  group('allocation caps hold before the bytes move (PR04)', () {
    test('a stream body above the per-request cap fails typed', () async {
      // A 200 KB stored page stream (incompressible, so the wire body
      // is large): the open's sample pass must demand it whole, and the
      // cap must refuse it before any allocation.
      final noise = Uint8List(200 << 10);
      var seed = 0x9e3779b9;
      for (var i = 0; i < noise.length; i++) {
        seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
        noise[i] = (seed >> 16) & 0xFF;
      }
      expect(ZLibCodec().encode(noise).length, greaterThan(96 << 10));
      final synthetic = _buildSyntheticPdf(streamBytes: noise);

      // The eager parse reads it fine — the cap is a byte-source
      // session budget, not a parser limit.
      expect((Unseal.parse(synthetic) as PdfBook).pageCount, 1);

      await expectLater(
        BookSession.openSource(
          FaultySource(synthetic),
          policy: const SessionPolicy(rangeRequestBytes: 96 << 10),
        ),
        throwsA(isA<ByteSourceLimitExceededException>()),
      );

      // Raising the policy cap serves the same document.
      final session = await BookSession.openSource(
        FaultySource(synthetic),
        policy: const SessionPolicy(rangeRequestBytes: 1 << 20),
      );
      addTearDown(session.dispose);
      expect((session.book as PdfBook).pageCount, 1);
    });

    test('a demand cycle that cannot converge fails typed, not forever', () async {
      // A source that answers every read with zeros of the right
      // length: the structure parse runs, finds nothing, and the
      // document fails typed exactly like the eager parse does on
      // zero-filled bytes.
      final zeros = Uint8List(4096);
      zeros.setRange(0, 8, convert.ascii.encode('%PDF-1.4'));
      await expectLater(BookSession.openSource(FaultySource(zeros)), throwsA(isA<PdfException>()));
    });
  });
}
