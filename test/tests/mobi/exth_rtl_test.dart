import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/mobi/header/exth_header.dart';

void main() {
  group('EXTH page progression (record 527) and writing mode (record 525)', () {
    test('reads the page progression direction and primary writing mode', () {
      final header = ExthHeader.parse(_exth({527: 'rtl', 525: 'horizontal-rl'}), 'utf-8', 'Title');

      expect(header.pageProgressionDirection, 'rtl');
      expect(header.primaryWritingMode, 'horizontal-rl');
    });

    test('returns null when the records are absent', () {
      final header = ExthHeader.parse(_exth({100: 'Author'}), 'utf-8', 'Title');

      expect(header.pageProgressionDirection, isNull);
      expect(header.primaryWritingMode, isNull);
    });

    test('treats an empty payload as absent', () {
      final header = ExthHeader.parse(_exth({527: '', 525: ''}), 'utf-8', 'Title');

      expect(header.pageProgressionDirection, isNull);
      expect(header.primaryWritingMode, isNull);
    });

    test('keeps the default marker through', () {
      final header = ExthHeader.parse(_exth({527: 'default'}), 'utf-8', 'Title');

      expect(header.pageProgressionDirection, 'default');
    });
  });
}

/// Builds a raw EXTH block (bytes start at the `EXTH` magic) carrying
/// one string payload per [records] entry.
Uint8List _exth(final Map<int, String> records) {
  Uint8List utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

  final payloads = <int, Uint8List>{
    for (final entry in records.entries) entry.key: utf8(entry.value),
  };
  final bodyLength = payloads.values.fold<int>(
    0,
    (final sum, final value) => sum + 8 + value.length,
  );
  final totalLength = 12 + bodyLength;
  final bytes = Uint8List(totalLength);
  final view = ByteData.sublistView(bytes);

  bytes.setRange(0, 4, utf8('EXTH'));
  view.setUint32(4, totalLength);
  view.setUint32(8, payloads.length);

  var pos = 12;
  for (final entry in payloads.entries) {
    view.setUint32(pos, entry.key);
    view.setUint32(pos + 4, 8 + entry.value.length);
    bytes.setRange(pos + 8, pos + 8 + entry.value.length, entry.value);
    pos += 8 + entry.value.length;
  }

  return bytes;
}
