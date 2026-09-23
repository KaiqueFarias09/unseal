import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../mobi/header/pdb_header.dart';
import '../palmdoc/palmdoc_compression.dart';
import 'plucker_bitmap.dart';
import 'plucker_html.dart';

const _maxBookBytes = 64 * 1024 * 1024;
const _maxRecords = 8192;
const _maxTextRecordBytes = 32768;
const _maxCompressedRecordBytes = 8192;

/// Reads Plucker pages, links, inline styles, and monochrome Palm images.
///
/// Color bitmap variants, external URLs, and owner-keyed documents remain
/// outside this reading projection.
DocumentBook parsePluckerBook(final Uint8List bytes) {
  final source = _PluckerSource.read(bytes);
  final paragraphs = <_PluckerParagraph>[];
  final images = <BinaryFile>[];
  final imagePaths = <int, String>{};
  var imageBytes = 0;
  for (var index = 1; index < source.pdb.count; index++) {
    final record = source.pdb.record(index);
    if (record.length < 8) {
      throw const InvalidBookException('Truncated Plucker data record.');
    }
    final type = record[6];
    if (type != 2 && type != 3) continue;
    final view = ByteData.sublistView(record);
    final uid = view.getUint16(0);
    final size = view.getUint16(4);
    if (imagePaths.containsKey(uid) || images.length >= 512) {
      throw const InvalidBookException('Duplicate or excessive Plucker image records.');
    }
    final bitmap = _decodeText(record, 8, size, compressed: type == 3, version: source.version);
    Uint8List png;
    try {
      png = decodePluckerBitmap(bitmap);
    } on FormatNotSupportedException {
      continue;
    }
    imageBytes += png.length;
    if (imageBytes > 32 * 1024 * 1024) {
      throw const InvalidBookException('Plucker images exceed the 32 MiB output limit.');
    }
    final path = 'images/$uid.png';
    imagePaths[uid] = path;
    images.add(BinaryFile(content: png, name: '$uid.png', type: 'png', path: path));
  }
  var totalTextBytes = 0;
  Uint8List? continuedParagraph;
  int? continuedType;
  int? continuedUid;
  int? continuedIndex;

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
    final uid = ByteData.sublistView(record).getUint16(0);
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
        continuedUid ??= uid;
        continuedIndex ??= paragraph;
      } else {
        paragraphs.add(_PluckerParagraph(continuedUid ?? uid, continuedIndex ?? paragraph, part));
        continuedUid = null;
        continuedIndex = null;
      }
    }
  }

  if (continuedParagraph != null) {
    throw const InvalidBookException('Plucker text continuation is missing its next record.');
  }

  if (paragraphs.isEmpty) {
    throw const FormatNotSupportedException('Plucker document has no readable text pages.');
  }
  final metadata = source.metadata;
  final htmlPath = _documentPath(source.pdb.name);
  final textIds = <int>{for (final paragraph in paragraphs) paragraph.uid};
  final html = StringBuffer('<!doctype html><html><head><meta charset="utf-8"></head><body>');
  final seenRecords = <int>{};
  final headings = <NavPoint>[];
  for (final paragraph in paragraphs) {
    if (seenRecords.add(paragraph.uid)) html.write('<span id="r${paragraph.uid}"></span>');
    final anchor = 'r${paragraph.uid}-p${paragraph.index}';
    html.write('<span id="$anchor"></span>');
    final content = renderPluckerParagraph(
      paragraph.data,
      textIds: textIds,
      imagePaths: imagePaths,
    );
    final isHeading = RegExp(r'^<h[1-6]>.*</h[1-6]>$').hasMatch(content);
    if (isHeading) {
      html.write(content);
      final label = html_parser.parseFragment(content).text?.trim() ?? '';
      if (label.isNotEmpty) {
        headings.add(
          NavPoint(
            classAttribute: '',
            id: 'nav-${headings.length + 1}',
            playOrder: '${headings.length + 1}',
            label: label,
            content: '$htmlPath#$anchor',
          ),
        );
      }
    } else {
      html.write('<p>$content</p>');
    }
    if (html.length > 2 * _maxBookBytes) {
      throw const InvalidBookException('Rendered Plucker HTML exceeds the 128 MiB limit.');
    }
  }
  html.write('</body></html>');
  if (html.length > 2 * _maxBookBytes) {
    throw const InvalidBookException('Rendered Plucker HTML exceeds the 128 MiB limit.');
  }
  return DocumentBook(
    format: BookFormat.plucker,
    files: Files(
      images: images,
      css: const <TextFile>[],
      html: <TextFile>[
        TextFile(name: htmlPath, type: 'html', path: htmlPath, content: html.toString()),
      ],
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    metadata: metadata,
    navigation: Navigation(
      title: metadata.title ?? 'Contents',
      navPoints: headings.isNotEmpty
          ? headings
          : <NavPoint>[
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

String _documentPath(final String name) {
  final stem = name
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '_')
      .replaceFirst(RegExp(r'^\.+'), '');
  return '${stem.isEmpty ? 'index' : stem}.html';
}

final class _PluckerParagraph {
  const _PluckerParagraph(this.uid, this.index, this.data);

  final int uid;
  final int index;
  final Uint8List data;
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
