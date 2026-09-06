import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _outputDirectory = 'test/resources/books/comic';

void main() {
  final directory = Directory(_outputDirectory)..createSync(recursive: true);
  File('${directory.path}/synthetic-pages.cbz').writeAsBytesSync(_buildCbz(), flush: true);
  File('${directory.path}/synthetic-stored-pages.cbr').writeAsBytesSync(_buildCbr(), flush: true);
}

Uint8List _buildCbz() {
  const comicInfo = '''
<?xml version="1.0"?>
<ComicInfo>
  <Title>eLivre Synthetic Comic</Title>
  <Series>Parser Fixtures</Series>
  <Number>1</Number>
  <Writer>eLivre contributors</Writer>
  <LanguageISO>mul</LanguageISO>
  <Summary>Generated test data with no third-party creative content.</Summary>
</ComicInfo>
''';
  final png = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );
  final archive = Archive()
    ..addFile(_archiveFile('002.png', png))
    ..addFile(_archiveFile('001.png', png))
    ..addFile(_archiveFile('ComicInfo.xml', utf8.encode(comicInfo)));

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _archiveFile(final String name, final List<int> bytes) =>
    ArchiveFile(name, bytes.length, bytes)..lastModTime = 946684800;

Uint8List _buildCbr() {
  final builder = BytesBuilder(copy: false)..add(const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);

  void addStoredFile(final String name, final List<int> data) {
    final nameBytes = ascii.encode(name);
    final headerSize = 32 + nameBytes.length;
    final header = ByteData(headerSize);
    var offset = 2; // Header CRC is intentionally unchecked by the fixture reader.
    header.setUint8(offset, 0x74);
    offset += 1;
    header.setUint16(offset, 0x8000, Endian.little);
    offset += 2;
    header.setUint16(offset, headerSize, Endian.little);
    offset += 2;
    header.setUint32(offset, data.length, Endian.little);
    offset += 4;
    header.setUint32(offset, data.length, Endian.little);
    offset += 4;
    header.setUint8(offset, 0);
    offset += 1;
    offset += 8; // File CRC and DOS timestamp.
    header.setUint8(offset, 29);
    offset += 1;
    header.setUint8(offset, 0x30); // Stored, not compressed.
    offset += 1;
    header.setUint16(offset, nameBytes.length, Endian.little);
    offset += 2;
    header.setUint32(offset, 0x20, Endian.little);
    offset += 4;
    header.buffer.asUint8List().setRange(offset, offset + nameBytes.length, nameBytes);
    builder
      ..add(header.buffer.asUint8List())
      ..add(data);
  }

  addStoredFile('002.jpg', const [0xFF, 0xD8, 0xFF, 0xE0, 4, 5, 6]);
  addStoredFile('001.jpg', const [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

  final end = ByteData(7)
    ..setUint8(2, 0x7B)
    ..setUint16(3, 0x4000, Endian.little)
    ..setUint16(5, 7, Endian.little);
  builder.add(end.buffer.asUint8List());

  return builder.takeBytes();
}
