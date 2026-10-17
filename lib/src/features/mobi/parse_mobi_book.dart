import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import 'codec/mobi_text_codec.dart';
import 'entities/entities.dart';
import 'header/mobi_header.dart';
import 'header/mobi_layout.dart';
import 'header/pdb_header.dart';
import 'metadata/mobi_metadata.dart';
import 'reader/mobi6_markup.dart';
import 'reader/mobi8_reader.dart';
import 'reader/mobi_text.dart';

/// Parses a MOBI / AZW3 book from raw [bytes] into a [MobiBook].
MobiBook parseMobiBook(final Uint8List bytes) {
  final pdb = PdbHeader.parse(bytes);
  var header = MobiHeader.parse(pdb.record(0), pdb.ident);
  assertNotDrm(header, pdb.name);
  final layout = resolveMobiLayout(pdb, header);
  header = layout.header;
  if (layout.isKf8) return _parseKf8(pdb, header, layout);

  return _parseMobi6(pdb, header);
}

/// Reads only the metadata of a MOBI / AZW3 book from [bytes].
BookMetadata readMobiMetadata(final Uint8List bytes) {
  final pdb = PdbHeader.parse(bytes);
  final header = MobiHeader.parse(pdb.record(0), pdb.ident);
  final format = detectMobiFormat(pdb, header);
  final cover = readMobiCoverRecord(pdb, header.firstImageIndex, header.exth?.coverOffset);

  return mobiBookMetadata(header, pdbName: pdb.name, coverFile: cover, formatOverride: format);
}

MobiBook _parseKf8(final PdbHeader pdb, final MobiHeader header, final MobiLayout layout) {
  final reader = Mobi8Reader(
    pdb: pdb,
    header: header,
    textOffset: layout.textOffset,
    resourceOffsets: layout.resourceOffsets,
    huffOffsetOverride: layout.huffOffsetOverride,
  );
  final assembly = reader.assemble();
  final cover = _resolveCover(pdb, header, assembly.images, preferredName: assembly.coverName);

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
  final cover = _resolveCover(pdb, header, resources.images, imageNames: resources.imageNames);
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

BinaryFile _resolveCover(
  final PdbHeader pdb,
  final MobiHeader header,
  final List<BinaryFile> images, {
  final String? preferredName,
  final Map<int, String> imageNames = const <int, String>{},
}) {
  final coverOffset = header.exth?.coverOffset;
  final coverName = preferredName ?? (coverOffset == null ? null : imageNames[coverOffset + 1]);
  if (coverName != null) {
    for (final image in images) {
      if (image.name == coverName) return image;
    }
  }

  return _readCoverRecord(pdb, header.firstImageIndex, coverOffset) ?? BinaryFile.empty();
}

BinaryFile? _readCoverRecord(
  final PdbHeader pdb,
  final int firstImageIndex,
  final int? coverOffset,
) => readMobiCoverRecord(pdb, firstImageIndex, coverOffset);
