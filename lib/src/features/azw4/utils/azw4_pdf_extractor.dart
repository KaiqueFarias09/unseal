import 'dart:typed_data';

import 'package:e_livre/src/features/mobi/exceptions/mobi_exception.dart';
import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';

import '../exceptions/azw4_exception.dart';

/// The PDF payload recovered from an AZW4 wrapper.
final class Azw4PdfPayload {
  /// Creates an extracted PDF payload with optional MOBI/PDB title metadata.
  const Azw4PdfPayload(this.bytes, {this.title});

  /// The exact PDF bytes that should be handed to the PDF parser/viewer.
  final Uint8List bytes;

  /// The MOBI/PDB title, when the wrapper carried one.
  final String? title;
}

/// Extracts the embedded PDF from an AZW4/PalmDB wrapper.
///
/// AZW4 files are MOBI-shaped PalmDB containers whose readable payload is a
/// PDF. The record path is preferred because it removes PalmDB record padding
/// and preserves the offsets used by the embedded PDF. A bounded signature
/// fallback mirrors Calibre's practical recovery path for damaged/nonstandard
/// wrappers without scanning unbounded input or accepting an incomplete PDF.
Azw4PdfPayload extractAzw4PdfPayload(final Uint8List bytes) {
  if (bytes.length > _maxAzw4Bytes) {
    throw const Azw4InvalidContainerException('AZW4 container exceeds the safe size limit.');
  }

  final pdb = _readPdb(bytes);
  if (pdb != null) {
    final recordPdf = _extractFromRecords(pdb.header);
    if (recordPdf != null) {
      return Azw4PdfPayload(recordPdf, title: pdb.title);
    }

    final fallbackPdf = _findCompletePdf(
      bytes,
      scanLimit: _maxFallbackScanBytes,
      payloadLimit: _maxFallbackPdfBytes,
    );
    if (fallbackPdf != null) return Azw4PdfPayload(fallbackPdf, title: pdb.title);

    throw const Azw4PdfNotFoundException('AZW4 container has no embedded PDF.');
  }

  final fallbackPdf = _findCompletePdf(
    bytes,
    scanLimit: _maxFallbackScanBytes,
    payloadLimit: _maxFallbackPdfBytes,
  );
  if (fallbackPdf != null) return Azw4PdfPayload(fallbackPdf);

  throw const Azw4PdfNotFoundException('AZW4 data has no complete embedded PDF.');
}

/// Extracts only the embedded PDF bytes from [bytes].
Uint8List extractAzw4Pdf(final Uint8List bytes) => extractAzw4PdfPayload(bytes).bytes;

final class _PdbDetails {
  const _PdbDetails(this.header, this.title);

  final PdbHeader header;
  final String? title;
}

const int _maxAzw4Bytes = 512 * 1024 * 1024;
const int _maxFallbackScanBytes = 32 * 1024 * 1024;
const int _maxFallbackPdfBytes = 512 * 1024 * 1024;
const List<int> _pdfMagic = <int>[0x25, 0x50, 0x44, 0x46];
const List<int> _pdfEof = <int>[0x25, 0x25, 0x45, 0x4F, 0x46];

_PdbDetails? _readPdb(final Uint8List bytes) {
  if (bytes.length < 68) return null;
  final ident = _ascii(bytes, 60, 8);
  if (ident != 'BOOKMOBI' && ident != 'TEXTREAD') return null;

  final PdbHeader header;
  try {
    header = PdbHeader.parse(bytes);
    _validateRecordTable(header, bytes);
  } on InvalidBookException catch (error) {
    throw Azw4InvalidContainerException(error.message);
  } on RangeError catch (error) {
    throw Azw4InvalidContainerException('Invalid AZW4 PalmDB record table: $error');
  }

  String? title;
  try {
    final record0 = header.record(0);
    if (_ascii(record0, 16, 4) == 'MOBI') {
      final mobi = MobiHeader.parse(record0, header.ident);
      try {
        assertNotDrm(mobi, header.name);
      } on DrmProtectedException catch (error) {
        throw Azw4DrmProtectedException(error.message);
      }
      title = _nonEmpty(mobi.title) ?? _nonEmpty(header.name);
    } else {
      title = _nonEmpty(header.name);
    }
  } on Azw4DrmProtectedException {
    rethrow;
  } on MobiException catch (error) {
    throw Azw4InvalidContainerException('Invalid AZW4 MOBI header: ${error.message}');
  } on RangeError catch (error) {
    throw Azw4InvalidContainerException('Invalid AZW4 MOBI header: $error');
  }

  return _PdbDetails(header, title);
}

void _validateRecordTable(final PdbHeader header, final Uint8List bytes) {
  final minimumRecordOffset = 78 + header.recordCount * 8;
  for (var index = 0; index < header.recordCount; index++) {
    final offset = header.offsets[index];
    if (offset < minimumRecordOffset || offset >= bytes.length) {
      throw const InvalidBookException('Invalid AZW4 PalmDB record offset.');
    }
    final length = header.recordLength(index);
    if (length <= 0 || offset + length > bytes.length) {
      throw const InvalidBookException('Invalid AZW4 PalmDB record length.');
    }
  }
}

Uint8List? _extractFromRecords(final PdbHeader header) {
  final records = BytesBuilder(copy: false);
  try {
    for (var index = 0; index < header.recordCount; index++) {
      records.add(header.record(index));
    }
  } on RangeError catch (_) {
    throw const Azw4InvalidContainerException('AZW4 PalmDB record data is outside the container.');
  }

  final recordBytes = records.takeBytes();

  return _findCompletePdf(recordBytes, scanLimit: recordBytes.length, payloadLimit: _maxAzw4Bytes);
}

Uint8List? _findCompletePdf(
  final Uint8List bytes, {
  required final int scanLimit,
  required final int payloadLimit,
}) {
  final boundedScanLimit = scanLimit < bytes.length ? scanLimit : bytes.length;
  for (var offset = 0; offset + _pdfMagic.length <= boundedScanLimit; offset++) {
    if (!_matches(bytes, offset, _pdfMagic)) continue;
    final end = _findLastEof(bytes, offset, payloadLimit);
    if (end == null) continue;

    return Uint8List.fromList(bytes.sublist(offset, end));
  }

  return null;
}

int? _findLastEof(final Uint8List bytes, final int start, final int payloadLimit) {
  final boundedEnd = <int>[
    bytes.length,
    start + payloadLimit,
  ].reduce((final a, final b) => a < b ? a : b);
  int? lastEnd;
  for (var offset = start; offset + _pdfEof.length <= boundedEnd; offset++) {
    if (_matches(bytes, offset, _pdfEof)) lastEnd = offset + _pdfEof.length;
  }

  return lastEnd;
}

bool _matches(final Uint8List bytes, final int offset, final List<int> pattern) {
  if (offset < 0 || offset + pattern.length > bytes.length) return false;
  for (var index = 0; index < pattern.length; index++) {
    if (bytes[offset + index] != pattern[index]) return false;
  }

  return true;
}

String _ascii(final Uint8List bytes, final int offset, final int length) {
  if (offset < 0 || offset + length > bytes.length) return '';

  return String.fromCharCodes(bytes.sublist(offset, offset + length));
}

String? _nonEmpty(final String value) => value.trim().isEmpty ? null : value.trim();
