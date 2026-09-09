import 'dart:typed_data';

import 'package:e_livre/src/features/mobi/codec/mobi_binary.dart';
import 'package:e_livre/src/features/mobi/entities/entities.dart';
import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/features/mobi/metadata/mobi_metadata.dart';
import 'package:e_livre/src/features/mobi/reader/mobi6_markup.dart';
import 'package:e_livre/src/features/mobi/reader/mobi8_reader.dart';
import 'package:e_livre/src/features/mobi/reader/mobi_text.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import '../../foundation/images/image_type_sniffer.dart';

class _MobiLayout {
  const _MobiLayout(
    this.isKf8,
    this.header,
    this.textOffset,
    this.resourceOffsets,
    this.huffOffsetOverride,
  );

  final bool isKf8;
  final MobiHeader header;
  final int textOffset;
  final List<(int, int)> resourceOffsets;
  final int? huffOffsetOverride;
}

/// Parses a MOBI / AZW3 book from raw [bytes] into a [MobiBook].
MobiBook parseMobiBook(final Uint8List bytes) {
  final pdb = PdbHeader.parse(bytes);
  var header = MobiHeader.parse(pdb.record(0), pdb.ident);
  assertNotDrm(header, pdb.name);
  final layout = _resolveLayout(pdb, header);
  header = layout.header;
  if (layout.isKf8) return _parseKf8(pdb, header, layout);

  return _parseMobi6(pdb, header);
}

/// Reads only the metadata of a MOBI / AZW3 book from [bytes].
BookMetadata readMobiMetadata(final Uint8List bytes) {
  final pdb = PdbHeader.parse(bytes);
  final header = MobiHeader.parse(pdb.record(0), pdb.ident);
  final format = _detectFormat(pdb, header);
  final cover = _readCoverRecord(pdb, header.firstImageIndex, header.exth?.coverOffset);

  return mobiBookMetadata(header, pdbName: pdb.name, coverFile: cover, formatOverride: format);
}

BookFormat _detectFormat(final PdbHeader pdb, final MobiHeader header) {
  if (header.mobiVersion == 8 && header.skelIndex != nullIndex) return BookFormat.azw3;

  final k8i = header.exth?.kf8HeaderIndex;
  if (k8i != null && k8i >= 1 && k8i - 1 < pdb.count) {
    if (_hasBoundary(pdb.record(k8i - 1))) return BookFormat.azw3;
  }

  return BookFormat.mobi;
}

bool _hasBoundary(final Uint8List record) =>
    record.length >= 8 && String.fromCharCodes(record.sublist(0, 8)) == 'BOUNDARY';

_MobiLayout _resolveLayout(final PdbHeader pdb, final MobiHeader header) {
  if (header.mobiVersion == 8 && header.skelIndex != nullIndex) {
    // Standalone KF8 (AZW3).
    return _MobiLayout(true, header, 1, [
      (_firstResourceIndex(header.firstImageIndex, header.textRecordCount, 1), pdb.count),
    ], null);
  }

  final k8i = header.exth?.kf8HeaderIndex;
  if (k8i != null && k8i >= 1 && k8i - 1 < pdb.count) {
    if (_hasBoundary(pdb.record(k8i - 1))) {
      // Joint MOBI 6 + KF8 file: parse the KF8 half.
      final kf8Header = MobiHeader.parse(pdb.record(k8i), pdb.ident);
      final kf8FirstImage = kf8Header.firstImageIndex + k8i;
      final textOffset = k8i + 1;

      return _MobiLayout(true, kf8Header, textOffset, [
        (_firstResourceIndex(header.firstImageIndex, header.textRecordCount, 1), k8i - 1),
        (_firstResourceIndex(kf8FirstImage, kf8Header.textRecordCount, textOffset), pdb.count),
      ], kf8Header.huffOffset + k8i);
    }
  }

  // Plain MOBI 6.

  return _MobiLayout(false, header, 1, [
    (_firstResourceIndex(header.firstImageIndex, header.textRecordCount, 1), pdb.count),
  ], null);
}

int _firstResourceIndex(
  final int firstImageIndex,
  final int textRecordCount,
  final int firstTextRecord,
) {
  return firstImageIndex != -1 && firstImageIndex != nullIndex
      ? firstImageIndex
      : textRecordCount + firstTextRecord;
}

MobiBook _parseKf8(final PdbHeader pdb, final MobiHeader header, final _MobiLayout layout) {
  final reader = Mobi8Reader(
    pdb: pdb,
    header: header,
    textOffset: layout.textOffset,
    resourceOffsets: layout.resourceOffsets,
    huffOffsetOverride: layout.huffOffsetOverride,
  );
  final assembly = reader.assemble();
  final coverName = assembly.coverName;
  BinaryFile cover = BinaryFile.empty();

  if (coverName != null) {
    for (final image in assembly.images) {
      if (image.name == coverName) {
        cover = image;
        break;
      }
    }
  }
  if (cover.isEmpty) {
    final fallback = _readCoverRecord(pdb, header.firstImageIndex, header.exth?.coverOffset);
    if (fallback != null) {
      cover = fallback;
    }
  }

  return MobiBook(
    navigation: assembly.navigation,
    files: Files(
      images: assembly.images,
      css: assembly.css,
      html: assembly.html,
      fonts: assembly.fonts,
      others: const <BinaryFile>[],
    ),
    cover: cover,
    header: header,
    format: BookFormat.azw3,
  );
}

MobiBook _parseMobi6(final PdbHeader pdb, final MobiHeader header) {
  final rawHtml = extractMobiText(
    recordAt: pdb.record,
    recordCount: pdb.count,
    textOffset: 1,
    header: header,
  );
  final processed = <int>{0};
  for (var i = 1; i <= header.textRecordCount && i < pdb.count; i++) {
    processed.add(i);
  }
  if (header.compressionType == 0x4448) {
    for (
      var i = header.huffOffset;
      i < header.huffOffset + header.huffRecordCount && i < pdb.count;
      i++
    ) {
      processed.add(i);
    }
  }
  final resources = extractMobi6Resources(
    recordAt: pdb.record,
    recordCount: pdb.count,
    firstImageIndex: header.firstImageIndex,
    processedRecords: processed,
  );
  final anchored = addFileposAnchors(rawHtml);
  final html = processMobi6Html(decodeBytes(anchored, header.codec), resources.imageNames);
  final navigation = deriveMobi6Navigation(html, header.exth?.title ?? header.title);
  BinaryFile cover = BinaryFile.empty();
  final coverOffset = header.exth?.coverOffset;

  if (coverOffset != null) {
    final name = resources.imageNames[coverOffset + 1];
    if (name != null) {
      for (final image in resources.images) {
        if (image.name == name) {
          cover = image;
          break;
        }
      }
    }
  }
  if (cover.isEmpty) {
    final fallback = _readCoverRecord(pdb, header.firstImageIndex, coverOffset);
    if (fallback != null) {
      cover = fallback;
    }
  }
  final htmlFile = TextFile(name: 'index.html', type: 'html', path: 'index.html', content: html);

  return MobiBook(
    navigation: navigation,
    files: Files(
      images: resources.images,
      css: const <TextFile>[],
      html: [htmlFile],
      fonts: resources.fonts,
      others: const <BinaryFile>[],
    ),
    cover: cover,
    header: header,
    format: BookFormat.mobi,
  );
}

BinaryFile? _readCoverRecord(
  final PdbHeader pdb,
  final int firstImageIndex,
  final int? coverOffset,
) {
  final base = firstImageIndex > 0 ? firstImageIndex : 1;
  final candidates = <int>[if (coverOffset != null) base + coverOffset, base];

  for (final index in candidates) {
    if (index < 0 || index >= pdb.count) continue;

    final data = pdb.record(index);
    final type = sniffImageType(data);
    if (type == null) continue;

    final name = 'cover.${type.fileExtension}';

    return BinaryFile(content: data, name: name, type: type.fileExtension, path: name);
  }

  return null;
}
