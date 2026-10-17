import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../../../foundation/exceptions/unseal_exception.dart';
import '../../../foundation/images/image_type_sniffer.dart';
import 'mobi_header.dart';
import 'pdb_header.dart';

/// The resolved reading layout of a MOBI family file: which half of the
/// record space holds the text, where resources start, and whether the
/// payload is KF8. Shared by the eager parse and progressive sessions
/// so both select the same payload.
class MobiLayout {
  /// Creates a layout from the resolved payload parts.
  const MobiLayout(
    this.isKf8,
    this.header,
    this.textOffset,
    this.resourceOffsets,
    this.huffOffsetOverride,
  );

  /// Whether the selected payload is KF8 (AZW3); false is plain MOBI 6.
  final bool isKf8;

  /// The MOBI header governing the selected payload (the KF8 header for
  /// joint files).
  final MobiHeader header;

  /// First text record index: 1 for standalone files, the KF8 boundary
  /// plus 2 for joint files.
  final int textOffset;

  /// (start, end) record ranges holding resources — two ranges for
  /// joint MOBI 6 + KF8 files, one otherwise.
  final List<(int, int)> resourceOffsets;

  /// Rebases the HUFF section for joint MOBI 6 + KF8 files.
  final int? huffOffsetOverride;
}

/// Chooses the MOBI 6 or KF8 payload of [pdb] under [header], mirroring
/// the dispatch the eager parse has always applied: a standalone KF8
/// header wins, then a joint file's `BOUNDARY`-marked KF8 half, then
/// plain MOBI 6.
MobiLayout resolveMobiLayout(final PdbRecordAccess pdb, final MobiHeader header) {
  if (header.mobiVersion == 8 && header.skelIndex != nullIndex) {
    // Standalone KF8 (AZW3).
    return MobiLayout(true, header, 1, [
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

      return MobiLayout(true, kf8Header, textOffset, [
        (_firstResourceIndex(header.firstImageIndex, header.textRecordCount, 1), k8i - 1),
        (_firstResourceIndex(kf8FirstImage, kf8Header.textRecordCount, textOffset), pdb.count),
      ], kf8Header.huffOffset + k8i);
    }
  }

  // Plain MOBI 6.
  return MobiLayout(false, header, 1, [
    (_firstResourceIndex(header.firstImageIndex, header.textRecordCount, 1), pdb.count),
  ], null);
}

/// Parses and DRM-checks record 0 of [pdb], then resolves its layout.
///
/// The session open path shares the eager contract exactly: DRM fails
/// with [DrmProtectedException], malformed headers fail with the MOBI
/// exceptions. [bookName] feeds the DRM failure message, like the
/// eager parse's PDB name.
MobiLayout parseMobiLayout(final PdbRecordAccess pdb, final String bookName) {
  final header = MobiHeader.parse(pdb.record(0), pdb.ident);
  assertNotDrm(header, bookName);

  return resolveMobiLayout(pdb, header);
}

/// Distinguishes AZW3 from MOBI 6 the way the eager parse labels books.
BookFormat detectMobiFormat(final PdbRecordAccess pdb, final MobiHeader header) {
  if (header.mobiVersion == 8 && header.skelIndex != nullIndex) return BookFormat.azw3;

  final k8i = header.exth?.kf8HeaderIndex;
  if (k8i != null && k8i >= 1 && k8i - 1 < pdb.count) {
    if (_hasBoundary(pdb.record(k8i - 1))) return BookFormat.azw3;
  }

  return BookFormat.mobi;
}

bool _hasBoundary(final Uint8List record) {
  return record.length >= 8 && String.fromCharCodes(record.sublist(0, 8)) == 'BOUNDARY';
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

/// The record-level cover lookup the eager parse falls back to: the
/// EXTH cover record, then the first image record, sniffing for an
/// image header.
BinaryFile? readMobiCoverRecord(
  final PdbRecordAccess pdb,
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
