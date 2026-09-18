import 'dart:typed_data';

import '../../../foundation/exceptions/elivre_exception.dart';
import '../codec/mobi_text_codec.dart';
import '../exceptions/mobi_exception.dart';
import 'exth_header.dart';

/// The MOBI header (record 0) of a MOBI / AZW3 file.
class MobiHeader {
  /// Parses the MOBI header from [record0] (with PDB [ident]).
  MobiHeader.parse(final Uint8List record0, this.ident) {
    final view = ByteData.sublistView(record0);
    compressionType = record0.length >= 2 ? view.getUint16(0) : 0;
    textRecordCount = record0.length >= 10 ? view.getUint16(8) : 0;
    textRecordSize = record0.length >= 12 ? view.getUint16(10) : 0;
    encryptionType = record0.length >= 14 ? view.getUint16(12) : 0;
    ancient = record0.length <= 16;

    if (ancient) {
      _initializeAncient();
      return;
    }

    _parseModern(record0, view);
  }

  void _initializeAncient() {
    codec = 'cp1252';
    extraFlags = 0;
    title = '';
    langCode = 0;
    mobiVersion = 1;
    firstImageIndex = -1;
    exth = null;
    headerLength = 0;
    codepage = 1252;
    uniqueId = 0;
    fileVersion = 0;
    ncxIndex = nullIndex;
    divIndex = skelIndex = othIndex = fdstIndex = nullIndex;
    fdstCount = 0;
    huffOffset = huffRecordCount = 0;
    doctype = '';
  }

  void _parseModern(final Uint8List record0, final ByteData view) {
    if (record0.length < 0x84) throw const InvalidBookException('Truncated MOBI header.');

    doctype = String.fromCharCodes(record0.sublist(16, 20));
    headerLength = view.getUint32(20);
    codepage = view.getUint32(28);
    uniqueId = view.getUint32(32);
    fileVersion = view.getUint32(36);
    codec = codepage == 65001 ? 'utf-8' : 'cp1252';
    _parseCompressionDetails(record0, view);
    _parseTitleAndVersion(record0, view);
    _parseExth(record0, view);
    _parseKf8Indexes(record0, view);
  }

  void _parseCompressionDetails(final Uint8List record0, final ByteData view) {
    const maxHeaderLength = 500;
    if (ident == 'TEXTREAD' || headerLength < 0xE4 || headerLength > maxHeaderLength) {
      extraFlags = 0;
    } else if (0xF2 + 2 <= record0.length) {
      extraFlags = view.getUint16(0xF2);
    } else {
      extraFlags = 0;
    }
    if (compressionType == 0x4448) {
      huffOffset = view.getUint32(0x70);
      huffRecordCount = view.getUint32(0x74);
    } else {
      huffOffset = 0;
      huffRecordCount = 0;
    }
  }

  void _parseTitleAndVersion(final Uint8List record0, final ByteData view) {
    final titleOffset = view.getUint32(0x54);
    final titleLength = view.getUint32(0x58);
    final titleEnd = titleOffset + titleLength;

    title = titleEnd <= record0.length && titleLength > 0
        ? decodeBytes(Uint8List.sublistView(record0, titleOffset, titleEnd), codec).trim()
        : '';
    langCode = view.getUint32(0x5C);
    mobiVersion = view.getUint32(0x68);
    firstImageIndex = view.getUint32(0x6C);
  }

  void _parseExth(final Uint8List record0, final ByteData view) {
    final exthFlag = view.getUint32(0x80);
    if ((exthFlag & 0x40) != 0) {
      // EXTH is optional metadata. A stale flag or a damaged marker
      // must not discard otherwise readable book content, while the
      // sublist operation remains outside this recovery boundary so a
      // malformed mandatory header length still fails strictly.
      final exthStart = 16 + headerLength;
      if (exthStart > record0.length) {
        throw const InvalidBookException('MOBI header exceeds record 0.');
      }

      final rawExth = Uint8List.sublistView(record0, exthStart);
      try {
        exth = ExthHeader.parse(rawExth, codec, title);
      } on MobiException {
        exth = null;
      }
    } else {
      exth = null;
    }
  }

  void _parseKf8Indexes(final Uint8List record0, final ByteData view) {
    ncxIndex = record0.length >= 0xF8 ? view.getUint32(0xF4) : nullIndex;
    if (mobiVersion == 8 && record0.length >= 0xF8 + 16) {
      divIndex = view.getUint32(0xF8);
      skelIndex = view.getUint32(0xFC);
      // 0x100 datpIndex (unused), 0x104 othIndex
      othIndex = view.getUint32(0x104);
      fdstCount = view.getUint32(0xC4);
      fdstIndex = fdstCount > 1 ? view.getUint32(0xC0) : nullIndex;
    } else {
      divIndex = skelIndex = othIndex = fdstIndex = nullIndex;
      fdstCount = 0;
    }
  }

  /// The PDB type identifier this header was parsed under.
  final String ident;

  /// Raw compression type: 1 none, 2 PalmDoc, `DH` (0x4448) HUFF.
  late final int compressionType;

  /// Number of text records.
  late final int textRecordCount;

  /// Size of a text record.
  late final int textRecordSize;

  /// Encryption type; non-zero means DRM protected.
  late final int encryptionType;

  /// Whether the header is a pre-MOBI (ancient) short header.
  late final bool ancient;

  /// The `MOBI` doctype marker.
  late final String doctype;

  /// MOBI header length field.
  late final int headerLength;

  /// Text codepage (1252 or 65001).
  late final int codepage;

  /// The text codec name: `utf-8` or `cp1252`.
  late final String codec;

  /// Unique id field.
  late final int uniqueId;

  /// File version field.
  late final int fileVersion;

  /// Extra data flags (trailing entries on text records).
  late final int extraFlags;

  /// Offset (record index) of the HUFF section, when compressed so.
  late final int huffOffset;

  /// Number of HUFF/CDIC records.
  late final int huffRecordCount;

  /// Title from the MOBI header (offset 0x54).
  late final String title;

  /// Packed locale word.
  late final int langCode;

  /// MOBI format version (6 or 8).
  late final int mobiVersion;

  /// Index of the first image record.
  late final int firstImageIndex;

  /// The EXTH header, when present.
  late final ExthHeader? exth;

  /// NCX index record (KF8), or [nullIndex].
  late final int ncxIndex;

  /// DIV index record (KF8), or [nullIndex].
  late final int divIndex;

  /// Skeleton index record (KF8), or [nullIndex].
  late final int skelIndex;

  /// Other (guide) index record (KF8), or [nullIndex].
  late final int othIndex;

  /// FDST record index (KF8), or [nullIndex].
  late final int fdstIndex;

  /// Number of FDST sections.
  late final int fdstCount;

  /// Index of the first non-text record, bounded to the file.
  int get firstNonTextRecordIndex {
    return firstImageIndex == -1 || firstImageIndex == nullIndex
        ? textRecordCount + 1
        : firstImageIndex;
  }
}

/// The `null` record index sentinel used by MOBI headers.
const nullIndex = 0xFFFFFFFF;

/// Validates that [header] is not DRM protected.
void assertNotDrm(final MobiHeader header, final String bookName) {
  if (header.encryptionType != 0) {
    var name = bookName;
    if (name.isEmpty) {
      name = header.exth?.title ?? header.title;
    }
    throw DrmProtectedException(name.isEmpty ? 'This MOBI book is DRM protected.' : name);
  }
}
