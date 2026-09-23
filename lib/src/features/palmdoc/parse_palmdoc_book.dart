import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../mobi/header/pdb_header.dart';
import '../txt/parse_txt_book.dart';

const _maxPalmdocBytes = 64 * 1024 * 1024;
const _maxRecordInputBytes = 8192;
const _recordTextBytes = 4096;

/// Parses an unencrypted PalmDOC (TEXt/REAd) database as plain reading text.
DocumentBook parsePalmdocBook(final Uint8List bytes) {
  final source = _PalmdocSource.read(bytes);
  final output = BytesBuilder(copy: false);
  var total = 0;
  for (var index = 1; index <= source.textRecords; index++) {
    final record = source.pdb.record(index);
    if (record.length > _maxRecordInputBytes) {
      throw const InvalidBookException('PalmDOC text record exceeds the input limit.');
    }
    final decoded = source.compression == 1 ? record : _decompressRecord(record);
    if (decoded.length > _recordTextBytes) {
      throw const InvalidBookException('PalmDOC text record exceeds 4096 bytes.');
    }
    total += decoded.length;
    if (total > source.textLength + _recordTextBytes) {
      throw const InvalidBookException('PalmDOC text exceeds the declared length.');
    }
    output.add(decoded);
  }
  if (total < source.textLength) {
    throw const InvalidBookException('PalmDOC text is shorter than declared.');
  }
  final all = output.takeBytes();
  final text = Uint8List.sublistView(all, 0, source.textLength);
  final document = parseTxtBook(text, sourceName: source.pdb.name);
  final storedTitle = source.pdb.name.trim();
  final title = storedTitle.isEmpty ? null : storedTitle;
  final metadata = BookMetadata(format: BookFormat.palmdoc, title: title);

  return DocumentBook(
    format: BookFormat.palmdoc,
    files: document.files,
    metadata: metadata,
    navigation: Navigation(
      title: title ?? 'Contents',
      navPoints: <NavPoint>[
        NavPoint(
          classAttribute: '',
          id: 'nav-1',
          playOrder: '1',
          label: title ?? 'Document',
          content: document.files.html.single.path,
        ),
      ],
    ),
    order: <String>[document.files.html.single.path],
  );
}

/// Reads the Palm database title without expanding text records.
BookMetadata readPalmdocMetadata(final Uint8List bytes) {
  final source = _PalmdocSource.read(bytes);
  final title = source.pdb.name.trim();
  return BookMetadata(format: BookFormat.palmdoc, title: title.isEmpty ? null : title);
}

final class _PalmdocSource {
  const _PalmdocSource({
    required this.pdb,
    required this.compression,
    required this.textLength,
    required this.textRecords,
  });

  final PdbHeader pdb;
  final int compression;
  final int textLength;
  final int textRecords;

  factory _PalmdocSource.read(final Uint8List bytes) {
    if (bytes.length > _maxPalmdocBytes) {
      throw const InvalidBookException('PalmDOC exceeds the 64 MiB input limit.');
    }
    final pdb = PdbHeader.parse(bytes);
    if (pdb.ident != 'TEXTREAD') {
      throw const InvalidBookException('PalmDOC requires a TEXt/REAd database.');
    }
    final header = pdb.record(0);
    if (header.length < 16) {
      throw const InvalidBookException('Truncated PalmDOC record zero.');
    }
    if (header.length >= 20 && String.fromCharCodes(header.sublist(16, 20)) == 'MOBI') {
      throw const InvalidBookException('MOBI headers are not PalmDOC.');
    }
    final view = ByteData.sublistView(header);
    final compression = view.getUint16(0);
    final textLength = view.getUint32(4);
    final textRecords = view.getUint16(8);
    final recordSize = view.getUint16(10);
    if ((compression != 1 && compression != 2) ||
        textLength > _maxPalmdocBytes ||
        recordSize != _recordTextBytes ||
        textRecords == 0 ||
        textRecords >= pdb.count) {
      throw const InvalidBookException('Unsupported or invalid PalmDOC header.');
    }
    for (var i = 1; i < pdb.offsets.length; i++) {
      if (pdb.offsets[i] < pdb.offsets[i - 1]) {
        throw const InvalidBookException('PalmDOC records are out of order.');
      }
    }
    return _PalmdocSource(
      pdb: pdb,
      compression: compression,
      textLength: textLength,
      textRecords: textRecords,
    );
  }
}

Uint8List _decompressRecord(final Uint8List data) {
  final bytes = <int>[];
  var offset = 0;

  void append(final int value) {
    if (bytes.length >= _recordTextBytes) {
      throw const InvalidBookException('PalmDOC decompression limit exceeded.');
    }
    bytes.add(value);
  }

  while (offset < data.length) {
    final first = data[offset++];
    if (first >= 1 && first <= 8) {
      if (offset + first > data.length) {
        throw const InvalidBookException('Truncated PalmDOC literal run.');
      }
      for (var i = 0; i < first; i++) {
        append(data[offset++]);
      }
    } else if (first <= 0x7F) {
      append(first);
    } else if (first >= 0xC0) {
      append(0x20);
      append(first ^ 0x80);
    } else {
      if (offset >= data.length) {
        throw const InvalidBookException('Truncated PalmDOC back reference.');
      }
      final pair = (first << 8) | data[offset++];
      final distance = (pair & 0x3FFF) >> 3;
      final length = (pair & 7) + 3;
      if (distance == 0 || distance > bytes.length) {
        throw const InvalidBookException('Invalid PalmDOC back reference.');
      }
      for (var i = 0; i < length; i++) {
        append(bytes[bytes.length - distance]);
      }
    }
  }
  return Uint8List.fromList(bytes);
}
