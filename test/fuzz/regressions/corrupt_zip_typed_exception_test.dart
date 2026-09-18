import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

/// Regression: corrupt zip containers must fail TYPED.
///
/// Found by the fuzz mutation sweep: a seed EPUB/TXTZ with a few
/// flipped central-directory bytes escaped `BookReader.parseBook` as
/// package:archive's own `ArchiveException`, `RangeError` or
/// `FormatException` — outside the typed ELivreException contract.
/// All book zip decodes now route through a typed boundary guard.
void main() {
  test('flipped central-directory bytes throw InvalidBookException', () {
    final archive = Archive()
      ..addFile(
        ArchiveFile('book.txt', 12, Uint8List.fromList('hello Moderna'.codeUnits))
          ..lastModTime = 946684800,
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    // Corrupt the central directory signature region near the end.
    final corrupted = Uint8List.fromList(bytes);
    for (var index = bytes.length - 40; index < bytes.length - 20; index++) {
      corrupted[index] = 0xAB;
    }

    expect(() => BookReader.parseBook(corrupted), throwsA(isA<ELivreException>()));
    expect(() => BookReader.parseBook(corrupted), throwsA(isA<InvalidBookException>()));
  });

  test('central-directory offset beyond the buffer throws typed, not RangeError', () {
    // A minimal local header plus an EOCD whose central-directory
    // offset points past the end — the exact shape that made
    // package:archive throw a bare RangeError.
    final out = BytesBuilder(copy: false)
      ..add([0x50, 0x4B, 0x03, 0x04]) // local file header signature
      ..add(Uint8List(26)) // header fields
      ..add('a.txt'.codeUnits)
      ..add([0x50, 0x4B, 0x05, 0x06]) // EOCD signature
      ..add(Uint8List(12)) // disk/entry counts (zeros)
      ..add(_uint32(0)) // central directory size
      ..add(_uint32(100000)) // central directory offset: beyond EOF
      ..add(_uint16(0)); // comment length
    final bytes = out.toBytes();

    expect(() => BookReader.parseBook(bytes), throwsA(isA<ELivreException>()));
  });

  test('corrupt deflate payload throws typed even though headers decode', () {
    // Entries decode lazily in package:archive, so a hostile deflate
    // stream used to escape as FormatException('Filter error, bad
    // data') from CONTENT access, outside the typed boundary.
    final archive = Archive()
      ..addFile(
        ArchiveFile('book.txt', 512, Uint8List.fromList(('deterministic chapter. ' * 24).codeUnits))
          ..lastModTime = 946684800,
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    // Replace the 2-byte zlib header of the first entry's payload
    // (30-byte local header + 8-byte name) with an invalid stream
    // marker so inflation itself fails.
    final corrupted = Uint8List.fromList(bytes);
    corrupted[38] = 0xFF;
    corrupted[39] = 0xFF;

    expect(() => BookReader.parseBook(corrupted), throwsA(isA<ELivreException>()));
    expect(() => BookReader.parseBook(corrupted), throwsA(isA<InvalidBookException>()));
  });
}

Uint8List _uint32(final int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

Uint8List _uint16(final int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);
