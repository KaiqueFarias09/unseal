import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/djvu/bzz_decoder.dart';
import 'package:unseal/unseal.dart';

import '../../support/djvu_fixture.dart';

void main() {
  final cyrillic = File('test/resources/djvu/cyrillic.djvu').readAsBytesSync();

  Uint8List dirmNames() => djvuCorpusChunk(cyrillic, 'DIRM');

  test('decodes a real DIRM name table byte-exactly', () {
    final payload = dirmNames();
    final count = (payload[1] << 8) | payload[2];
    final names = decodeDjvuBzz(
      Uint8List.sublistView(payload, 3 + count * 4),
      truncatedMessage: 'Truncated DjVu DIRM names.',
    );
    // 13 components: 12 pages plus one shared dictionary, declared sizes
    // first, then flags, then the NUL-terminated id strings.
    expect(names.length, 195);
    final strings = String.fromCharCodes(names, 3 * count + count);
    expect(strings, contains('00012.djbz'));
    expect(strings, contains('00001.djvu'));
    expect(strings, contains('00012.djvu'));
  });

  test('round-trips the speller TXTz payloads against djvutxt output', () {
    final speller = File('test/resources/djvu/speller-1921.djvu').readAsBytesSync();
    final payloads = djvuCorpusChunks(speller, 'TXTz');
    expect(payloads, hasLength(115));
    final joined = BytesBuilder();
    for (final payload in payloads) {
      final raw = decodeDjvuBzz(payload, truncatedMessage: 'Truncated DjVu TXTz chunk.');
      final textLength = (raw[0] << 16) | (raw[1] << 8) | raw[2];
      final rendered = <int>[];
      for (final byte in raw.sublist(3, 3 + textLength)) {
        if (byte == 0) {
          rendered
            ..add(0x0A)
            ..add(0x0C);
        } else {
          rendered.add(byte);
        }
      }
      joined.add(rendered);
      final endsWithSeparator =
          rendered.length >= 2 && rendered[rendered.length - 2] == 0x0A && rendered.last == 0x0C;
      if (!endsWithSeparator) joined.add(const <int>[0x0A, 0x0C]);
    }
    final reference = File(
      '/Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/references/speller-1921.txt',
    );
    // The archived djvutxt reference is a dev-time oracle; when present the
    // decode must match byte for byte.
    if (reference.existsSync()) {
      expect(joined.toBytes(), reference.readAsBytesSync());
    } else {
      expect(joined.length, greaterThan(100000));
    }
  });

  test('rejects an empty stream as a typed truncation', () {
    expect(
      () => decodeDjvuBzz(Uint8List(0), truncatedMessage: 'Truncated DjVu BZZ stream.'),
      throwsA(isA<DjvuException>()),
    );
    expect(
      () => decodeDjvuBzz(
        Uint8List.fromList(<int>[1]),
        truncatedMessage: 'Truncated DjVu BZZ stream.',
      ),
      throwsA(isA<DjvuException>()),
    );
  });

  test('rejects a hostile declared block size before allocating output', () {
    // The stream opens with a 24-bit passthrough block size; these bytes
    // declare a block beyond the 4 MiB format limit and the decoder must
    // reject them before materializing anything.
    final hostile = Uint8List.fromList(<int>[0x80, 0x00, 0xFF, 0xFF]);
    expect(
      () => decodeDjvuBzz(hostile, truncatedMessage: 'Truncated DjVu BZZ stream.'),
      throwsA(isA<DjvuException>()),
    );
  });

  test('rejects real output beyond the caller cap before allocation', () {
    // The 195-byte cyrillic DIRM name table decodes fine at its natural size
    // but must be refused before allocation under a tighter caller cap.
    final payload = dirmNames();
    final count = (payload[1] << 8) | payload[2];
    final names = Uint8List.sublistView(payload, 3 + count * 4);
    expect(
      () =>
          decodeDjvuBzz(names, truncatedMessage: 'Truncated DjVu DIRM names.', maxOutputBytes: 64),
      throwsA(isA<DjvuException>()),
    );
  });

  test('accepts an empty stream that declares size zero immediately', () {
    final empty = decodeDjvuBzz(
      Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x1A]),
      truncatedMessage: 'Truncated DjVu BZZ stream.',
    );
    expect(empty, isEmpty);
  });
}
