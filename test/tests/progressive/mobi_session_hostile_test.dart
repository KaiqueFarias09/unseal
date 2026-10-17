import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/mobi/header/exth_header.dart';
import 'package:unseal/unseal.dart';

import '../mobi/mobi_fixture_builder.dart';

Uint8List _alice() => File('test/resources/books/mobi/alice-old-pg.mobi').readAsBytesSync();

/// Writes [records] through the fixture builder with [count] declared
/// in record 0 (the header record itself is prepended).
Uint8List _pdbWithCount(final int count, final List<Uint8List> records) {
  final full = buildPdb('Hostile', records);
  // Rewrite the declared record count at offset 76.
  final view = ByteData.sublistView(full, 76, 78)..setUint16(0, count);

  return full;
}

void main() {
  group('hostile PalmDB structure', () {
    test('truncated container fails typed', () async {
      final bytes = Uint8List.sublistView(_alice(), 0, 40);
      // Detection rejects the remnant before the PDB layer runs; the
      // eager parse reaches PdbHeader.parse and raises
      // InvalidBookException instead. Both are typed package failures.
      await expectLater(
        BookSession.open(bytes),
        throwsA(
          isA<UnsealException>().having(
            (final error) => error.message,
            'message',
            contains('format'),
          ),
        ),
      );
    });

    test('a zero record count fails typed', () async {
      final bytes = _pdbWithCount(0, [Uint8List(60)]);
      final corrupted = ByteData.sublistView(bytes)..setUint16(76, 0);

      await expectLater(
        BookSession.open(Uint8List.sublistView(corrupted)),
        throwsA(isA<InvalidBookException>()),
      );
    });

    test('record offsets outside the container fail typed', () async {
      final records = <Uint8List>[
        buildMobiRecord0(compressionType: 1, textRecordCount: 1, title: 'X'),
        Uint8List.fromList(convert.utf8.encode('<html><body><p>x</p></body></html>')),
      ];
      final full = buildPdb('BadOffsets', records);
      // Point record 1 past the container end.
      ByteData.sublistView(full, 86, 90).setUint32(0, full.length + 4096);

      await expectLater(BookSession.open(full), throwsA(isA<InvalidBookException>()));
    });

    test('a record count wider than the container fails typed', () async {
      final records = <Uint8List>[
        buildMobiRecord0(compressionType: 1, textRecordCount: 1, title: 'X'),
        Uint8List.fromList(convert.utf8.encode('<html><body><p>x</p></body></html>')),
      ];
      final full = buildPdb('BigCount', records);
      ByteData.sublistView(full, 76, 78).setUint16(0, 0xFFFF);

      await expectLater(BookSession.open(full), throwsA(isA<InvalidBookException>()));
    });

    test('unknown compression fails typed at open', () async {
      final book = buildPdb('UnknownCompression', [
        buildMobiRecord0(compressionType: 0x5350, textRecordCount: 1, title: 'X'),
        Uint8List.fromList(convert.utf8.encode('<html><body><p>x</p></body></html>')),
      ]);

      await expectLater(BookSession.open(book), throwsA(isA<MobiException>()));
    });

    test('a HUFF section pointing outside the record space fails typed', () async {
      final book = buildPdb('BadHuff', [
        buildMobiRecord0(
          compressionType: 0x4448,
          textRecordCount: 1,
          huffOffset: 900,
          huffRecordCount: 4,
          title: 'X',
        ),
        Uint8List.fromList(convert.utf8.encode('<html><body><p>x</p></body></html>')),
      ]);

      await expectLater(BookSession.open(book), throwsA(isA<MobiException>()));
    });

    test('an exth-declared KF8 boundary outside the file fails typed or falls back', () async {
      final exth = buildExth([(ExthIds.kf8Header, Uint8List(4)..buffer.asByteData().setUint32(0, 5000))]);
      final book = buildPdb('BadKf8Boundary', [
        buildMobiRecord0(
          compressionType: 1,
          textRecordCount: 1,
          title: 'X',
          exth: exth,
        ),
        Uint8List.fromList(convert.utf8.encode('<html><body><p>x</p></body></html>')),
      ]);

      // The boundary record cannot exist; the eager dispatch rules
      // keep this a plain MOBI 6, and the session opens it as such.
      final session = await BookSession.open(book);
      try {
        expect((session.book as MobiBook).format, BookFormat.mobi);
      } finally {
        session.dispose();
      }
    });
  });

  group('DRM', () {
    test('encrypted MOBI refuses with the typed DRM failure', () async {
      final book = buildPdb('DrmedSession', [
        buildMobiRecord0(
          compressionType: 1,
          textRecordCount: 1,
          encryptionType: 2,
          title: 'Locked',
        ),
        Uint8List.fromList(convert.utf8.encode('<html><body><p>x</p></body></html>')),
      ]);

      await expectLater(BookSession.open(book), throwsA(isA<DrmProtectedException>()));
    });

    test('the file open path refuses the same way', () async {
      final dir = await Directory.systemTemp.createTemp('unseal-mobi-hostile');
      addTearDown(() => dir.delete(recursive: true));
      final book = buildPdb('DrmedFile', [
        buildMobiRecord0(
          compressionType: 1,
          textRecordCount: 1,
          encryptionType: 2,
          title: 'Locked',
        ),
        Uint8List.fromList(convert.utf8.encode('<html><body><p>x</p></body></html>')),
      ]);
      final path = '${dir.path}/locked.mobi';
      File(path).writeAsBytesSync(book);

      await expectLater(BookSession.openFile(path), throwsA(isA<DrmProtectedException>()));
    });
  });

  group('file opens', () {
    test('a real book opens from its path with the same reading order', () async {
      final session = await BookSession.openFile('test/resources/books/mobi/alice-old-pg.mobi');
      try {
        expect(session.book.readingOrder, isNotEmpty);
        expect(session.byteLength, _alice().length);
        final text = await session.loadDocumentText(session.book.readingOrder.first.name);
        expect(text, contains('Alice'));
      } finally {
        session.dispose();
      }
    });

    test('a missing file fails with a file-system error', () async {
      await expectLater(
        BookSession.openFile('test/resources/books/mobi/does-not-exist.mobi'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
