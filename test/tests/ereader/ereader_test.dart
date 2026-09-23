import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

  test('eReader preserves Calibre PML styles, local links and PNG resources', () {
    final bytes = Uint8List.fromList(
      File('test/resources/books/format_expansion/ereader-rich.pdb').readAsBytesSync(),
    );
    final book = parseEreaderBook(bytes);
    final html = book.files.html.single.content;
    expect(html, contains('<strong>bold phrase</strong>'));
    expect(html, contains('<em>italic phrase</em>'));
    expect(html, contains('<a href="#calibre_link-2">note reference</a>'));
    expect(html, contains('<span id="calibre_link-2"></span>'));
    expect(html, contains('<img src="images/cover.png" alt=""/>'));
    expect(book.files.images, hasLength(1));
    expect(book.files.images.single.name, 'cover.png');
    expect(book.files.images.single.content.take(8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    expect(book.navigation.navPoints, isNotEmpty);
    expect(book.navigation.navPoints.first.content, contains('#pml-heading-'));
  });

  test('eReader retains footnote records and local note references', () {
    final rich = Uint8List.fromList(
      File('test/resources/books/format_expansion/ereader-rich.pdb').readAsBytesSync(),
    );
    final withNotes = _withFootnote(rich);
    final book = parseEreaderBook(withNotes);
    expect(book.files.html.single.content, contains('<a href="#fn-hint">Note</a>'));
    expect(book.files.html.single.content, contains('<aside id="fn-hint">An extra note.</aside>'));

    final malformed = Uint8List.fromList(withNotes);
    final recordZero = ByteData.sublistView(malformed).getUint32(78);
    ByteData.sublistView(malformed).setUint16(recordZero + 48, 65535);
    expect(() => parseEreaderBook(malformed), throwsA(isA<InvalidBookException>()));
  });

  test('eReader rejects a damaged image before exposing it', () {
    final bytes = Uint8List.fromList(
      File('test/resources/books/format_expansion/ereader-rich.pdb').readAsBytesSync(),
    );
    final recordZero = ByteData.sublistView(bytes).getUint32(78);
    final imageIndex = ByteData.sublistView(bytes).getUint16(recordZero + 40);
    final imageOffset = ByteData.sublistView(bytes).getUint32(78 + imageIndex * 8);
    bytes[imageOffset + 62] = 0;
    expect(() => parseEreaderBook(bytes), throwsA(isA<InvalidBookException>()));
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

Uint8List _withFootnote(final Uint8List input) {
  final original = ByteData.sublistView(input);
  final count = original.getUint16(76);
  final offsets = <int>[
    for (var index = 0; index < count; index++) original.getUint32(78 + index * 8),
    input.length,
  ];
  final records = <Uint8List>[
    for (var index = 0; index < count; index++)
      Uint8List.fromList(input.sublist(offsets[index], offsets[index + 1])),
  ];
  final recordZero = ByteData.sublistView(records[0]);
  recordZero
    ..setUint16(28, 2)
    ..setUint16(48, count);
  final originalText = const ZLibDecoder().decodeBytes(records[1]);
  records[1] = Uint8List.fromList(
    const ZLibEncoder().encode(<int>[...originalText, ...r'\Fn="hint"Note\Fn'.codeUnits]),
  );
  records
    ..add(Uint8List.fromList('hint\u0000'.codeUnits))
    ..add(Uint8List.fromList(const ZLibEncoder().encode(utf8.encode('An extra note.'))));
  final header = Uint8List(78 + records.length * 8)..setRange(0, 78, input);
  final view = ByteData.sublistView(header)..setUint16(76, records.length);
  var offset = header.length;
  for (var index = 0; index < records.length; index++) {
    view.setUint32(78 + index * 8, offset);
    offset += records[index].length;
  }
  final output = BytesBuilder(copy: false)..add(header);
  for (final record in records) {
    output.add(record);
  }
  return output.takeBytes();
}
