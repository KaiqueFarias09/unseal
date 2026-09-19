import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/pdf/codec/pdf_stream_decoder.dart';
import 'package:unseal/src/features/pdf/header/pdf_object.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('LZWDecode filter', () {
    const payload = 'BT /F1 12 Tf 72 720 Td (LZW works) Tj ET';

    test('round-trips a content stream through the greedy encoder', () {
      final encoded = lzwEncode(payload.codeUnits);
      final stream = PdfStream(const PdfDictionary({'Filter': PdfName('LZWDecode')}), encoded);
      final decoded = decodePdfStream(stream, _identity);

      expect(String.fromCharCodes(decoded), payload);
    });

    test('honours /EarlyChange 0 in /DecodeParms', () {
      final encoded = lzwEncode(payload.codeUnits, earlyChange: 0);
      final stream = PdfStream(
        const PdfDictionary({
          'Filter': PdfName('LZWDecode'),
          'DecodeParms': PdfDictionary({'EarlyChange': PdfNumber(0)}),
        }),
        encoded,
      );

      expect(String.fromCharCodes(decodePdfStream(stream, _identity)), payload);
    });

    test('keeps the code width in sync across the 9-12 bit boundaries', () {
      // A varied payload long enough to grow the dictionary past
      // every width bump (511/1023/2047 entries under the default
      // early change) and past the 4096-entry freeze.
      final bytes = _pseudoRandomBytes(40000);
      for (final earlyChange in const [1, 0]) {
        final encoded = lzwEncode(bytes, earlyChange: earlyChange);
        final stream = PdfStream(
          PdfDictionary({
            'Filter': PdfName('LZWDecode'),
            'DecodeParms': PdfDictionary({'EarlyChange': PdfNumber(earlyChange.toDouble())}),
          }),
          encoded,
        );

        expect(decodePdfStream(stream, _identity), bytes, reason: 'earlyChange=$earlyChange');
      }
    });

    test('decodes a real PDF whose content stream uses /Filter /LZWDecode', () {
      final book = parsePdfBook(
        buildOnePagePdf(
          contentBytes: lzwEncode(payload.codeUnits).toList(),
          contentDictionary: ' /Filter /LZWDecode',
        ),
      );
      final page = book.pageTexts.single;

      expect(page.text, 'LZW works');
      expect(DocumentTextScanner(book.files.html.single.content).scan(), page.text);
    });

    test('rejects codes outside the dictionary with a PdfException', () {
      // 0x81 0x00 packs the 9-bit code 258 — the first free entry,
      // undefined right after the start with no previous code.
      expect(
        () => decodePdfStream(
          PdfStream(
            const PdfDictionary({'Filter': PdfName('LZWDecode')}),
            Uint8List.fromList([0x81, 0x00]),
          ),
          _identity,
        ),
        throwsA(isA<PdfException>()),
      );
    });
  });

  group('rotated text boxes', () {
    // Tm [0 1 -1 0 100 700]: the text direction u = (0, 1) runs up
    // the page, the vertical direction v = (-1, 0) runs left.
    const content = 'BT /F1 12 Tf 0 1 -1 0 100 700 Tm (Rotated) Tj ET';

    late PdfBook book;

    setUp(() {
      book = parsePdfBook(buildOnePagePdf(contentBytes: content.codeUnits));
    });

    test('extracts the line rotated with the exact axis-aligned box', () {
      final line = book.pageTexts.single.lines.single;

      expect(line.text, 'Rotated');
      expect(line.rotated, isTrue);
      expect(line.x, closeTo(100, 0.01));
      expect(line.fontSize, closeTo(12, 0.01));
      // The box width sweeps the 0.8 em ascent along v = (-1, 0):
      // 12 x 0.8 = 9.6 points; the advance runs on the y axis.
      expect(line.width, closeTo(9.6, 0.01));
      expect(line.height, closeTo(12, 0.01));
    });

    test('keeps the canonical invariant on the rotated page', () {
      expect(
        DocumentTextScanner(book.files.html.single.content).scan(),
        book.pageTexts.single.text,
      );
    });
  });

  group('PDF robustness fuzz', () {
    const seed = 20260906;
    const iterations = 250;

    final sources = <String, Uint8List>{
      'dickens-sample.pdf': File('test/resources/pdf/dickens-sample.pdf').readAsBytesSync(),
      'synthetic one-pager': buildOnePagePdf(contentBytes: _fuzzContent.codeUnits),
    };

    /// A mutation may parse, or fail the designed way; anything else
    /// escaping the exception surface is a robustness defect.
    void expectTolerant(final Uint8List bytes, final String description) {
      try {
        parsePdfBook(bytes);
      } on PdfException {
        // The rejection path (includes PdfEncryptedException).
      } on FormatNotSupportedException {
        // Also acceptable for byte soup.
      } catch (error, stackTrace) {
        fail(
          '$description escaped the PDF exception surface: '
          '${error.runtimeType}: $error\n$stackTrace',
        );
      }
    }

    test('random 1-8 byte flips either parse or throw a PDF exception', () {
      for (final source in sources.entries) {
        final random = Random(seed);
        for (var i = 0; i < iterations; i++) {
          final mutated = Uint8List.fromList(source.value);
          final flips = 1 + random.nextInt(8);
          for (var flip = 0; flip < flips; flip++) {
            mutated[random.nextInt(mutated.length)] = random.nextInt(256);
          }
          expectTolerant(mutated, 'source=${source.key} iteration=$i flips=$flips');
        }
      }
    });

    test('random truncation either parses or throws a PDF exception', () {
      for (final source in sources.entries) {
        final random = Random(seed);
        for (var i = 0; i < iterations; i++) {
          final length = 1 + random.nextInt(source.value.length);
          expectTolerant(
            Uint8List.sublistView(source.value, 0, length),
            'source=${source.key} iteration=$i length=$length/${source.value.length}',
          );
        }
      }
    });

    test('header bit flips either parse or throw a PDF exception', () {
      for (final source in sources.entries) {
        final random = Random(seed);
        for (var i = 0; i < iterations; i++) {
          final mutated = Uint8List.fromList(source.value);
          final offset = i % 16; // fixed positions inside the %PDF header block
          final mask = 1 << random.nextInt(8);
          mutated[offset] ^= mask;
          expectTolerant(
            mutated,
            'source=${source.key} iteration=$i header offset=$offset mask=$mask',
          );
        }
      }
    });
  });
}

PdfObject? _identity(final PdfObject? object) => object;

const _fuzzContent =
    'BT /F1 12 Tf 72 720 Td (Synthetic fuzz page one) Tj ET\n'
    'BT /F1 12 Tf 72 700 Td [(Second) -20 (line)] TJ ET\n';

/// A deterministic pseudo-random byte generator (an LCG, so the fuzz
/// payload never changes between runs).
Uint8List _pseudoRandomBytes(final int length) {
  final out = Uint8List(length);
  var state = 20260906;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x3FFFFFFF;
    out[i] = (state >> 16) & 0xFF;
  }

  return out;
}

/// A minimal greedy LZW encoder following the PDF convention: the
/// dictionary starts with the 256 literals plus clear (256) and EOD
/// (257), codes are big-endian bit-packed, and the width bumps
/// 9 -> 10 -> 11 -> 12 as entries are added — `/EarlyChange` moves
/// each bump one entry early, symmetrically on both sides. Each code
/// is emitted at the width the *decoder* will have when it reads it:
/// the decoder cannot add an entry until its second code, so its
/// table view lags one entry behind the encoder's, and the encoder
/// lags its emission width to match.
Uint8List lzwEncode(final List<int> input, {final int earlyChange = 1}) {
  final table = <String, int>{for (var i = 0; i < 256; i++) String.fromCharCode(i): i};
  var nextCode = 258;
  var width = 9; // reflects every entry added so far
  var emitWidth = 9; // the decoder's lagged view at this code position
  final codes = <int>[];
  final widths = <int>[];

  void emit(final int code) {
    codes.add(code);
    widths.add(emitWidth);
    emitWidth = width;
  }

  var current = '';
  for (final byte in input) {
    final extended = current + String.fromCharCode(byte);
    if (table.containsKey(extended)) {
      current = extended;
      continue;
    }
    emit(table[current]!);
    if (nextCode < 4096) {
      table[extended] = nextCode++;
      if (nextCode + earlyChange == 512) {
        width = 10;
      } else if (nextCode + earlyChange == 1024) {
        width = 11;
      } else if (nextCode + earlyChange == 2048) {
        width = 12;
      }
    }
    current = String.fromCharCode(byte);
  }
  if (current.isNotEmpty) emit(table[current]!);
  emit(257); // EOD

  final out = BytesBuilder(copy: false);
  var bitBuffer = 0;
  var bitCount = 0;
  for (var i = 0; i < codes.length; i++) {
    bitBuffer = (bitBuffer << widths[i]) | codes[i];
    bitCount += widths[i];
    while (bitCount >= 8) {
      bitCount -= 8;
      out.addByte((bitBuffer >> bitCount) & 0xFF);
    }
    bitBuffer &= (1 << bitCount) - 1;
  }
  if (bitCount > 0) out.addByte((bitBuffer << (8 - bitCount)) & 0xFF);

  return out.toBytes();
}

/// Assembles a minimal one-page PDF (classic cross-reference table,
/// Helvetica Type1 font) whose content stream holds [contentBytes]
/// with the extra stream-dictionary entries in [contentDictionary] —
/// the local fixture shape this suite needs, built inline.
Uint8List buildOnePagePdf({
  required final List<int> contentBytes,
  final String contentDictionary = '',
}) {
  final out = BytesBuilder(copy: false);
  out.add(<int>[0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A, 0x25]);
  out.add(<int>[0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

  final offsets = <int, int>{};
  void writeObject(final int number, final String body) {
    offsets[number] = out.length;
    out
      ..add('$number 0 obj\n'.codeUnits)
      ..add(body.codeUnits)
      ..add('endobj\n'.codeUnits);
  }

  writeObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  writeObject(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  writeObject(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
    '/Resources << /Font << /F1 5 0 R >> >> >>',
  );
  offsets[4] = out.length;
  out
    ..add('4 0 obj\n'.codeUnits)
    ..add('<< /Length ${contentBytes.length}$contentDictionary >>\n'.codeUnits)
    ..add('stream\n'.codeUnits)
    ..add(contentBytes)
    ..add('\nendstream\nendobj\n'.codeUnits);
  writeObject(
    5,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  );

  final xrefOffset = out.length;
  out.add('xref\n0 6\n0000000000 65535 f \n'.codeUnits);
  for (var number = 1; number <= 5; number++) {
    out.add('${offsets[number]!.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  out.add('trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF'.codeUnits);

  return out.toBytes();
}
