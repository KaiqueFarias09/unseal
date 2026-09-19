import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// Regression: zip expansion is bounded BEFORE inflation.
///
/// Found by the fuzz structural sweep: an honest high-ratio archive
/// (kilobytes of deflate-compressed zeros declaring megabytes) was
/// inflated unconditionally, so a hostile container could allocate
/// gigabytes from kilobytes. The guard reads the central directory's
/// declared sizes first and rejects over-cap containers typed.
void main() {
  test('high-ratio zip bomb is rejected by the expansion cap', () {
    // 64 MiB of zeros deflate to well under 100 KiB: a ~1000x
    // expansion ratio that real books never approach.
    final zeros = Uint8List(64 << 20);
    final archive = Archive()
      ..addFile(
        ArchiveFile('bomb.bin', zeros.length, Uint8List.fromList(const ZLibEncoder().encode(zeros)))
          ..lastModTime = 946684800,
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

    expect(
      () => Unseal.parse(bytes),
      throwsA(allOf(isA<UnsealException>(), isA<InvalidBookException>())),
    );
  });

  test('declared totals above the safety cap are rejected before decoding', () {
    // Two central-directory entries declaring 600 MiB each (1.2 GiB
    // total) inside a few hundred real bytes.
    final bytes = _zipWithDeclaredSizes(<int>[600 << 20, 600 << 20]);

    expect(() => Unseal.parse(bytes), throwsA(isA<InvalidBookException>()));
  });

  test('forged tiny size cannot bypass the streaming expansion cap', () {
    final zeros = Uint8List(34 << 20);
    final archive = Archive()..addFile(ArchiveFile('forged.bin', zeros.length, zeros));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final central = _signatureOffset(bytes, const <int>[0x50, 0x4B, 0x01, 0x02]);
    _writeUint32At(bytes, 22, 1); // local-header uncompressed size
    _writeUint32At(bytes, central + 24, 1); // central-directory uncompressed size

    expect(() => Unseal.parse(bytes), throwsA(isA<InvalidBookException>()));
  });

  test('legitimate books still parse after the caps', () {
    final chapter = Uint8List.fromList(('chapter text. ' * 293).codeUnits);
    final archive = Archive()
      ..addFile(ArchiveFile('book.txt', chapter.length, chapter)..lastModTime = 946684800)
      ..addFile(
        ArchiveFile('meta.xml', 29, Uint8List.fromList('<meta><title>t</title></meta>'.codeUnits))
          ..lastModTime = 946684800,
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

    // A small legitimate zip book still parses (text-backed zip book)
    // — the caps only reject hostile declared expansion.
    final book = Unseal.parse(bytes);
    expect(book, isA<Book>());
  });
}

/// Builds a container whose central directory declares [sizes]
/// uncompressed bytes per entry while every entry is stored-empty.
Uint8List _zipWithDeclaredSizes(final List<int> sizes) {
  final out = BytesBuilder(copy: false);
  final centralOffsets = <int>[];
  for (final _ in sizes) {
    centralOffsets.add(out.length);
    out.add([0x50, 0x4B, 0x03, 0x04]); // local header signature
    out.add(Uint8List(26));
    out.add('e.bin'.codeUnits);
  }
  final centralStart = out.length;
  for (var index = 0; index < sizes.length; index++) {
    out.add([0x50, 0x4B, 0x01, 0x02]); // central signature
    out.add(_uint16(20)); // version made by
    out.add(_uint16(20)); // version needed
    out.add(_uint16(0)); // flags
    out.add(_uint16(0)); // method: stored
    out.add(_uint16(0)); // mod time
    out.add(_uint16(0)); // mod date
    out.add(_uint32(0)); // crc
    out.add(_uint32(0)); // compressed size
    out.add(_uint32(sizes[index])); // UNCOMPRESSED size (declared)
    out.add(_uint16(5)); // name length
    out.add(_uint16(0)); // extra length
    out.add(_uint16(0)); // comment length
    out.add(_uint16(0)); // disk number
    out.add(_uint16(0)); // internal attrs
    out.add(_uint32(0)); // external attrs
    out.add(_uint32(centralOffsets[index])); // local header offset
    out.add('e.bin'.codeUnits);
  }
  final centralSize = out.length - centralStart;
  out.add([0x50, 0x4B, 0x05, 0x06]); // EOCD
  out.add(_uint16(0));
  out.add(_uint16(0));
  out.add(_uint16(sizes.length));
  out.add(_uint16(sizes.length));
  out.add(_uint32(centralSize));
  out.add(_uint32(centralStart));
  out.add(_uint16(0));

  return out.toBytes();
}

Uint8List _uint32(final int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

Uint8List _uint16(final int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);

int _signatureOffset(final Uint8List bytes, final List<int> signature) {
  for (var offset = 0; offset <= bytes.length - signature.length; offset++) {
    var matches = true;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return offset;
  }
  throw StateError('ZIP signature not found');
}

void _writeUint32At(final Uint8List bytes, final int offset, final int value) {
  ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);
}
