import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  final fixture = Uint8List.fromList(
    File('test/resources/books/format_expansion/ereader-sample.pdb').readAsBytesSync(),
  );

  test('eReader PDB exposes Calibre-produced text and metadata', () {
    expect(detectFormat(fixture), DetectedFormat.ereader);
    final book = parseEreaderBook(fixture);
    expect(book.format, BookFormat.ereader);
    expect(book.metadata.title, 'Unseal eReader Fixture');
    expect(book.metadata.authors, <String>['Unseal Test']);
    expect(book.files.html.single.content, contains('First chapter'));
    expect(book.files.html.single.content, contains('A final line.'));
    expect(book.files.html.single.content, isNot(contains(r'\c')));
    expect(book.readingOrder, hasLength(1));
    expect(Unseal.parse(fixture).format, BookFormat.ereader);
  });

  test('metadata-only read does not inflate text records', () {
    final damagedText = Uint8List.fromList(fixture);
    final recordStart = ByteData.sublistView(damagedText).getUint32(78 + 8);
    damagedText[recordStart] = 0;
    expect(readEreaderMetadata(damagedText).title, 'Unseal eReader Fixture');
    expect(() => parseEreaderBook(damagedText), throwsA(isA<InvalidBookException>()));
  });

  test('DRM and corrupt record boundaries return typed failures', () {
    final drm = Uint8List.fromList(fixture);
    final firstRecord = ByteData.sublistView(drm).getUint32(78);
    ByteData.sublistView(drm).setUint16(firstRecord, 260);
    expect(() => parseEreaderBook(drm), throwsA(isA<DrmProtectedException>()));

    final corrupt = Uint8List.fromList(fixture);
    ByteData.sublistView(corrupt).setUint16(firstRecord + 12, 65535);
    expect(() => parseEreaderBook(corrupt), throwsA(isA<InvalidBookException>()));
  });

  test('oversized compressed text record is rejected before expansion', () {
    final inflatedRecord = Uint8List.fromList(<int>[...fixture, ...List<int>.filled(9000, 0)]);
    final view = ByteData.sublistView(inflatedRecord);
    final nextRecordOffset = view.getUint32(78 + 16);
    for (var index = 2; index < view.getUint16(76); index++) {
      view.setUint32(78 + index * 8, view.getUint32(78 + index * 8) + 9000);
    }
    inflatedRecord.setRange(
      nextRecordOffset + 9000,
      inflatedRecord.length,
      fixture,
      nextRecordOffset,
    );
    expect(() => parseEreaderBook(inflatedRecord), throwsA(isA<InvalidBookException>()));
  });
}
