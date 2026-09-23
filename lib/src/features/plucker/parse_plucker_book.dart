import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../mobi/header/pdb_header.dart';
import '../palmdoc/palmdoc_compression.dart';
import '../txt/parse_txt_book.dart';

const _maxBookBytes = 64 * 1024 * 1024;
const _maxRecords = 8192;
const _maxTextRecordBytes = 32768;
const _maxCompressedRecordBytes = 8192;

/// Reads the textual pages of a Plucker PDB in record order.
///
/// Plucker images, links, styles and bookmarks are not represented in this
/// text projection. Owner-keyed compressed documents are not supported.
DocumentBook parsePluckerBook(final Uint8List bytes) {
  final source = _PluckerSource.read(bytes);
  final paragraphs = <Uint8List>[];
  var totalTextBytes = 0;
  Uint8List? continuedParagraph;
  int? continuedType;

  for (var index = 1; index < source.pdb.count; index++) {
    final record = source.pdb.record(index);
    if (record.length < 8) {
      throw const InvalidBookException('Truncated Plucker data record.');
    }
    final type = record[6];
    if (continuedParagraph != null && type != continuedType) {
      throw const InvalidBookException('Plucker text continuation has a different record type.');
    }
    if (type != 0 && type != 1) continue;
    final count = ByteData.sublistView(record).getUint16(2);
    final size = ByteData.sublistView(record).getUint16(4);
    if (count == 0 || count > _maxTextRecordBytes ~/ 4 || size > _maxTextRecordBytes) {
      throw const InvalidBookException('Invalid Plucker text record dimensions.');
    }
    final textStart = 8 + count * 4;
    if (textStart > record.length) {
      throw const InvalidBookException('Truncated Plucker paragraph table.');
    }
    final lengths = <int>[];
    var expectedSize = 0;
    final view = ByteData.sublistView(record);
    for (var paragraph = 0; paragraph < count; paragraph++) {
      final length = view.getUint16(8 + paragraph * 4);
      expectedSize += length;
      if (expectedSize > _maxTextRecordBytes) {
        throw const InvalidBookException('Plucker paragraph lengths exceed record limit.');
      }
      lengths.add(length);
    }
    if (expectedSize != size) {
      throw const InvalidBookException('Plucker paragraph lengths disagree with record size.');
    }
    final text = _decodeText(
      record,
      textStart,
      size,
      compressed: type == 1,
      version: source.version,
    );
    totalTextBytes += size;
    if (totalTextBytes > _maxBookBytes) {
      throw const InvalidBookException('Plucker text exceeds the 64 MiB limit.');
    }
    var offset = 0;
    for (var paragraph = 0; paragraph < lengths.length; paragraph++) {
      final length = lengths[paragraph];
      var part = Uint8List.sublistView(text, offset, offset + length);
      offset += length;
      if (paragraph == 0 && continuedParagraph != null) {
        final joined = BytesBuilder(copy: false)
          ..add(continuedParagraph)
          ..add(part);
        part = joined.takeBytes();
        continuedParagraph = null;
        continuedType = null;
      }
      if (paragraph == lengths.length - 1 && (record[7] & 0x01) != 0) {
        continuedParagraph = part;
        continuedType = type;
      } else {
        paragraphs.add(part);
      }
    }
  }

  if (continuedParagraph != null) {
    throw const InvalidBookException('Plucker text continuation is missing its next record.');
  }

  if (paragraphs.isEmpty) {
    throw const FormatNotSupportedException('Plucker document has no readable text pages.');
  }
  final document = parseTxtBook(
    Uint8List.fromList(utf8.encode(paragraphs.map(_stripFunctions).join('\n\n'))),
    sourceName: source.pdb.name,
  );
  final metadata = source.metadata;
  final htmlPath = document.files.html.single.path;
  return DocumentBook(
    format: BookFormat.plucker,
    files: document.files,
    metadata: metadata,
    navigation: Navigation(
      title: metadata.title ?? 'Contents',
      navPoints: <NavPoint>[
        NavPoint(
          classAttribute: '',
          id: 'nav-1',
          playOrder: '1',
          label: metadata.title ?? 'Document',
          content: htmlPath,
        ),
      ],
    ),
    order: <String>[htmlPath],
  );
}

/// Reads the database title without inflating Plucker content records.
BookMetadata readPluckerMetadata(final Uint8List bytes) => _PluckerSource.read(bytes).metadata;

Uint8List _decodeText(
  final Uint8List record,
  final int start,
  final int size, {
  required final bool compressed,
  required final int version,
}) {
  if (!compressed) {
    if (start + size > record.length) {
      throw const InvalidBookException('Truncated Plucker text record.');
    }
    return Uint8List.sublistView(record, start, start + size);
  }
  final encoded = Uint8List.sublistView(record, start);
  if (encoded.length > _maxCompressedRecordBytes || encoded.length >= size) {
    throw const InvalidBookException('Plucker compressed text record exceeds its input limit.');
  }
  late final Uint8List decoded;
  if (version == 1) {
    decoded = decompressPalmdocRecord(encoded, maxOutputBytes: _maxTextRecordBytes);
  } else {
    try {
      // This package decoder allocates before returning. Limiting compressed
      // input to 8 KiB bounds its transient expansion; the retained result
      // must match the declared size of at most 32 KiB.
      decoded = Uint8List.fromList(const ZLibDecoder().decodeBytes(encoded, verify: true));
    } on FormatException {
      throw const InvalidBookException('Invalid Plucker zlib text record.');
    }
  }
  if (decoded.length != size) {
    throw const InvalidBookException('Plucker decoded text length disagrees with header.');
  }
  return decoded;
}

String _stripFunctions(final Uint8List paragraph) {
  final text = StringBuffer();
  for (var index = 0; index < paragraph.length; index++) {
    final byte = paragraph[index];
    if (byte != 0) {
      text.writeCharCode(byte);
      continue;
    }
    if (++index >= paragraph.length) {
      throw const InvalidBookException('Truncated Plucker text function.');
    }
    final code = paragraph[index];
    final argumentBytes = code & 7;
    if (index + argumentBytes >= paragraph.length) {
      throw const InvalidBookException('Truncated Plucker text function argument.');
    }
    index += argumentBytes;
    if (code == 0x38) text.write('\n');
  }
  return text.toString();
}

final class _PluckerSource {
  const _PluckerSource(this.pdb, this.version);

  final PdbHeader pdb;
  final int version;

  static _PluckerSource read(final Uint8List bytes) {
    if (bytes.length > _maxBookBytes) {
      throw const InvalidBookException('Plucker PDB exceeds the 64 MiB input limit.');
    }
    final pdb = PdbHeader.parse(bytes);
    if (pdb.ident != 'DATAPLKR' || pdb.count < 2 || pdb.count > _maxRecords) {
      throw const InvalidBookException('Invalid Plucker PDB identity or record count.');
    }
    final index = pdb.record(0);
    if (index.length < 6) {
      throw const InvalidBookException('Truncated Plucker index.');
    }
    final view = ByteData.sublistView(index);
    final version = view.getUint16(2);
    if (view.getUint16(0) != 1 || (version != 1 && version != 2)) {
      throw const FormatNotSupportedException('Unsupported Plucker index or compression.');
    }
    final reserved = view.getUint16(4);
    if (reserved > (index.length - 6) ~/ 4) {
      throw const InvalidBookException('Truncated Plucker reserved record list.');
    }
    for (var i = 1; i < pdb.offsets.length; i++) {
      if (pdb.offsets[i] <= pdb.offsets[i - 1]) {
        throw const InvalidBookException('Invalid Plucker record order.');
      }
    }
    return _PluckerSource(pdb, version);
  }

  BookMetadata get metadata {
    final title = pdb.name.trim();
    return BookMetadata(format: BookFormat.plucker, title: title.isEmpty ? null : title);
  }
}
