import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/mobi/header/exth_header.dart';
import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/features/mobi/reader/mobi8_resources.dart';
import 'package:e_livre/src/features/mobi/reader/mobi_container.dart';
import 'package:test/test.dart';

import 'mobi_fixture_builder.dart';

void main() {
  group('HUFF-compressed MOBI', () {
    const html =
        '<html><head><title>T</title></head>'
        '<body><p>Hello from HUFF</p></body></html>';
    final textRecord = Uint8List.fromList(convert.utf8.encode(html));
    // Records: 0 header, 1 text (identity-compressed), 2..3 HUFF
    // section, 4 cover image.
    final book = buildPdb('SyntheticHuff', [
      buildMobiRecord0(
        compressionType: 0x4448,
        textRecordCount: 1,
        huffOffset: 2,
        huffRecordCount: 2,
        firstImageIndex: 4,
        title: 'Synthetic HUFF',
      ),
      textRecord,
      buildHuffHeader(),
      buildCdic(),
      tinyPng,
    ]);

    test('decompresses the text stream through the HUFF section', () {
      final parsed = parseMobiBook(book);
      expect(parsed.format, BookFormat.mobi);
      expect(parsed.files.html, hasLength(1));
      expect(parsed.files.html.single.content, html);
    });

    test('extracts resources and the cover', () {
      final parsed = parseMobiBook(book);
      expect(parsed.files.images.map((final image) => image.name), ['image00001.png']);
      expect(parsed.files.images.single.content, tinyPng);
      expect(parsed.cover.content, tinyPng);
    });

    test('reads metadata through the fast path', () {
      final metadata = BookReader.readMetadataSync(book);
      expect(metadata.title, 'Synthetic HUFF');
      expect(metadata.cover, isNotNull);
    });
  });

  group('MobiContainer', () {
    test('detects application/image containers', () {
      final container = MobiContainer(buildContRecord());
      expect(container.isImageContainer, isTrue);
    });

    test('rejects other resource types', () {
      final container = MobiContainer(buildContRecord(mime: 'application/x-font-otf'));
      expect(container.isImageContainer, isFalse);
      expect(container.loadImage(buildCresRecord(tinyPng)), isNull);
    });

    test('unwraps CRES payloads behind the 12-byte prefix', () {
      final container = MobiContainer(buildContRecord());
      final image = container.loadImage(buildCresRecord(tinyJpeg));
      expect(image, tinyJpeg);
      expect(container.resourceIndex, 1);
    });

    test('rejects short CRES payloads', () {
      final container = MobiContainer(buildContRecord());
      expect(container.loadImage(Uint8List.fromList('CRES'.codeUnits)), isNull);
    });

    test('rejects a truncated EXTH payload without leaking a range error', () {
      final record = buildContRecord();
      ByteData.sublistView(record).setUint32(64, 25);
      final truncated = Uint8List.sublistView(record, 0, 70);

      expect(MobiContainer(truncated).isImageContainer, isFalse);
    });
  });

  test('resource ranges keep independent container state and unique names', () {
    final records = _Records([buildContRecord(), buildCresRecord(tinyPng), tinyPng]);
    final resources = Mobi8Resources.extract(pdb: records, resourceOffsets: const [(0, 1), (1, 3)]);

    expect(resources.images.map((final image) => image.name), ['image00003.png']);
    expect(resources.resourceMap, [null, null, 'image00003.png']);
  });

  group('KF8 with CONT/CRES image containers', () {
    final original = File('test/resources/mobi/alice-kf8.azw3').readAsBytesSync();

    test('unwraps container images into the image list', () {
      final injected = appendPdbRecords(original, [buildContRecord(), buildCresRecord(tinyPng)]);
      final book = parseMobiBook(injected);
      final unwrapped = book.files.images
          .where((final image) => image.content.length == tinyPng.length)
          .toList();
      expect(unwrapped, isNotEmpty);
      expect(unwrapped.first.content, tinyPng);
      expect(unwrapped.first.type, 'png');
    });

    test('non-image containers keep their CRES payloads out', () {
      final injected = appendPdbRecords(original, [
        buildContRecord(mime: 'application/x-ptk-component'),
        buildCresRecord(tinyPng),
      ]);
      final book = parseMobiBook(injected);
      expect(
        book.files.images.where((final image) => image.content.length == tinyPng.length),
        isEmpty,
      );
    });
  });

  group('text stream edge cases', () {
    MobiBook buildBook(
      final int compressionType,
      final Uint8List textRecord, {
      final int codepage = 65001,
    }) {
      return parseMobiBook(
        buildPdb('Edge', [
          buildMobiRecord0(
            compressionType: compressionType,
            textRecordCount: 1,
            codepage: codepage,
          ),
          textRecord,
        ]),
      );
    }

    test('uncompressed text records pass through', () {
      final book = buildBook(1, Uint8List.fromList(convert.utf8.encode('<p>plain</p>#')));
      // The trailing '#' marker is dropped from the stream.
      expect(book.files.html.single.content, '<p>plain</p>');
    });

    test('strips control bytes from cp1252 text', () {
      final book = buildBook(
        1,
        Uint8List.fromList([0x3C, 0x70, 0x3E, 0x1E, 0x02, 0x61, 0x00, 0x3C]),
        codepage: 1252,
      );
      expect(book.files.html.single.content, '<p>a<');
    });

    test('unknown compression types throw', () {
      expect(
        () => buildBook(0x9999, Uint8List.fromList('<p>x</p>'.codeUnits)),
        throwsA(isA<MobiException>()),
      );
    });
  });

  group('MobiHeader', () {
    test('treats short pre-MOBI headers as ancient', () {
      final header = MobiHeader.parse(Uint8List(12), 'BOOKMOBI');
      expect(header.ancient, isTrue);
      expect(header.codec, 'cp1252');
      expect(header.mobiVersion, 1);
      expect(header.firstImageIndex, -1);
      expect(header.firstNonTextRecordIndex, 1);
    });

    test('reports truncated modern headers as invalid books', () {
      expect(
        () => MobiHeader.parse(Uint8List(17), 'BOOKMOBI'),
        throwsA(isA<InvalidBookException>()),
      );
    });

    test('reads a title that ends exactly at the record boundary', () {
      final full = buildMobiRecord0(title: 'Exact');
      final view = ByteData.sublistView(full);
      final titleEnd = view.getUint32(0x54) + view.getUint32(0x58);
      final exact = Uint8List.sublistView(full, 0, titleEnd);

      expect(MobiHeader.parse(exact, 'BOOKMOBI').title, 'Exact');
    });

    test('TEXTREAD headers never carry extra flags', () {
      final record = buildMobiRecord0(extraFlags: 0x0F);
      final header = MobiHeader.parse(record, 'TEXTREAD');
      expect(header.extraFlags, 0);
    });

    test('oversized header lengths drop the extra flags', () {
      final record = buildMobiRecord0(headerLength: 600, extraFlags: 0x0F);
      final header = MobiHeader.parse(record, 'BOOKMOBI');
      expect(header.extraFlags, 0);
    });

    test('KF8 headers without FDST sections null the index', () {
      final record = buildMobiRecord0(mobiVersion: 8, fdstCount: 1);
      final header = MobiHeader.parse(record, 'BOOKMOBI');
      expect(header.fdstIndex, nullIndex);
      expect(header.ncxIndex, nullIndex);
    });
  });

  group('DRM protection', () {
    test('throws with the EXTH updated title when present', () {
      final header = MobiHeader.parse(
        buildMobiRecord0(
          encryptionType: 2,
          exthFlags: 0x40,
          title: 'Old Title',
          exth: buildExth([(503, Uint8List.fromList(convert.utf8.encode('DRM Book')))]),
        ),
        'BOOKMOBI',
      );
      expect(
        () => assertNotDrm(header, ''),
        throwsA(
          isA<DrmProtectedException>().having(
            (final error) => error.toString(),
            'message',
            contains('DRM Book'),
          ),
        ),
      );
    });

    test('falls back to the header title', () {
      final header = MobiHeader.parse(
        buildMobiRecord0(encryptionType: 1, title: 'Paid Title'),
        'BOOKMOBI',
      );
      expect(() => assertNotDrm(header, ''), throwsA(isA<DrmProtectedException>()));
    });
  });

  group('ExthHeader', () {
    Uint8List u32(final int value) => (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

    test('malformed optional EXTH does not block book content', () {
      final malformed = buildExth([(503, Uint8List.fromList(convert.utf8.encode('EXTH title')))]);
      malformed.setRange(0, 4, 'BAD!'.codeUnits);
      final bytes = buildPdb('Malformed EXTH', [
        buildMobiRecord0(
          compressionType: 1,
          textRecordCount: 1,
          exthFlags: 0x40,
          title: 'Header',
          exth: malformed,
        ),
        Uint8List.fromList(convert.utf8.encode('<html><body>Recoverable</body></html>')),
      ]);

      final book = parseMobiBook(bytes);
      final metadata = readMobiMetadata(bytes);

      expect(book.header.exth, isNull);
      expect(book.metadata.title, 'Header');
      expect(book.files.html.single.content, contains('Recoverable'));
      expect(metadata.title, 'Header');
    });

    test('malformed optional EXTH does not bypass encryption rejection', () {
      final malformed = buildExth([
        (503, Uint8List.fromList(convert.utf8.encode('Protected EXTH title'))),
      ]);
      malformed.setRange(0, 4, 'BAD!'.codeUnits);
      final header = MobiHeader.parse(
        buildMobiRecord0(encryptionType: 1, exthFlags: 0x40, title: 'Protected', exth: malformed),
        'BOOKMOBI',
      );

      expect(() => assertNotDrm(header, ''), throwsA(isA<DrmProtectedException>()));
    });

    test('keeps truncated record content instead of throwing', () {
      final declared = buildExth([(100, Uint8List(100))]);
      final truncated = Uint8List.sublistView(declared, 0, 25);
      final exth = ExthHeader.parse(truncated, 'utf-8', '');
      expect(exth.rawValues(100).single.length, 5);
    });

    test('rawValues of a missing id is empty', () {
      final exth = ExthHeader.parse(
        buildExth([(100, Uint8List.fromList('a'.codeUnits))]),
        'utf-8',
        '',
      );
      expect(exth.rawValues(999), isEmpty);
    });

    test('exposes thumbnail offset and fake cover flag', () {
      final exth = ExthHeader.parse(buildExth([(202, u32(7)), (203, u32(1))]), 'utf-8', '');
      expect(exth.thumbnailOffset, 7);
      expect(exth.hasFakeCover, isTrue);
    });

    test('cover offset of 0xFFFFFFFF counts as absent', () {
      final exth = ExthHeader.parse(buildExth([(201, u32(0xFFFFFFFF))]), 'utf-8', '');
      expect(exth.coverOffset, isNull);
    });
  });

  group('sort keys and book producer', () {
    Uint8List buildBook(final List<(int, Uint8List)> exthRecords) {
      return buildPdb('Synthetic', [
        buildMobiRecord0(textRecordCount: 1, exthFlags: 0x40, exth: buildExth(exthRecords)),
        Uint8List.fromList(
          convert.utf8.encode('<html><head><title>T</title></head><body><p>x</p></body></html>'),
        ),
      ]);
    }

    test('maps EXTH 108 to the producer and keeps the Last, First sort form', () {
      final metadata = BookReader.readMetadataSync(
        buildBook([
          (100, Uint8List.fromList(convert.utf8.encode('Carroll, Lewis'))),
          (108, Uint8List.fromList(convert.utf8.encode('calibre (9.4.0)'))),
        ]),
      );
      expect(metadata.authors, ['Lewis Carroll']);
      expect(metadata.authorSort, 'Carroll, Lewis');
      expect(metadata.bookProducer, 'calibre (9.4.0)');
      expect(metadata.titleSort, isNull); // MOBI files carry no title sort
    });

    test('joins multiple author sort keys with an ampersand', () {
      final metadata = BookReader.readMetadataSync(
        buildBook([
          (100, Uint8List.fromList(convert.utf8.encode('Carroll, Lewis'))),
          (100, Uint8List.fromList(convert.utf8.encode('Tenniel, John'))),
        ]),
      );
      expect(metadata.authors, ['Lewis Carroll', 'John Tenniel']);
      expect(metadata.authorSort, 'Carroll, Lewis & Tenniel, John');
    });

    test('plain author names carry no sort key', () {
      final metadata = BookReader.readMetadataSync(
        buildBook([(100, Uint8List.fromList(convert.utf8.encode('Lewis Carroll')))]),
      );
      expect(metadata.authors, ['Lewis Carroll']);
      expect(metadata.authorSort, isNull);
      expect(metadata.bookProducer, isNull);
    });

    test('rejects impossible publication dates', () {
      final metadata = BookReader.readMetadataSync(
        buildBook([(106, Uint8List.fromList(convert.utf8.encode('2024-02-31')))]),
      );

      expect(metadata.publishedAt, isNull);
    });
  });
}

final class _Records implements PdbRecordAccess {
  const _Records(this.records);

  final List<Uint8List> records;

  @override
  int get count => records.length;

  @override
  Uint8List record(final int index) => records[index];
}
