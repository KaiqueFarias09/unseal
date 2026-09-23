import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import 'lrx_signature.dart';
import 'parse_lrf_book.dart';

const _maxLrxBytes = 128 * 1024 * 1024;
const _maxBoxes = 1024;

/// Reads plaintext metadata exposed by an LRX2 BBeB wrapper.
///
/// This reads only the nested LRF metadata stream. It does not inspect, decrypt,
/// or render the protected book payload. Older LRX files do not expose metadata
/// in this form and are reported as DRM-protected.
BookMetadata readLrxMetadata(final Uint8List bytes) {
  if (bytes.length > _maxLrxBytes) {
    throw const InvalidBookException('LRX file exceeds the size limit.');
  }
  if (hasLegacyLrxSignature(bytes)) {
    throw const DrmProtectedException('Legacy LRX content is DRM-protected.');
  }
  if (!hasLrx2Signature(bytes)) {
    throw const InvalidBookException('LRX2 signature is invalid.');
  }

  final data = ByteData.sublistView(bytes);
  final fileTypeBoxSize = _u32(data, 0, Endian.big);
  if (fileTypeBoxSize < 12 || fileTypeBoxSize > bytes.length - 8) {
    throw const InvalidBookException('LRX2 file type box is invalid.');
  }

  var offset = fileTypeBoxSize;
  for (var boxIndex = 0; boxIndex < _maxBoxes; boxIndex++) {
    if (offset > bytes.length - 8) break;
    final boxSize = _u32(data, offset, Endian.big);
    if (boxSize < 8 || boxSize > bytes.length - offset) {
      throw const InvalidBookException('LRX2 box size is invalid.');
    }
    if (_hasAscii(bytes, offset + 4, 'bbeb')) {
      final payloadOffset = offset + 8;
      final payloadLength = boxSize - 8;
      if (payloadLength < 0x53 || !_hasLrfSignature(bytes, payloadOffset, payloadLength)) {
        throw const InvalidBookException('LRX2 BBeB payload is invalid.');
      }
      final nested = Uint8List.sublistView(bytes, payloadOffset, payloadOffset + payloadLength);
      return readLrfMetadata(nested);
    }
    offset += boxSize;
  }

  throw const InvalidBookException('LRX2 BBeB box is missing.');
}

/// Throws the typed DRM failure used when a caller tries to read LRX content.
Never rejectLrxContent() =>
    throw const DrmProtectedException('LRX book content is DRM-protected and cannot be read.');

int _u32(final ByteData data, final int offset, final Endian endian) {
  if (offset < 0 || offset > data.lengthInBytes - 4) {
    throw const InvalidBookException('LRX2 box header is truncated.');
  }
  return data.getUint32(offset, endian);
}

bool _hasAscii(final Uint8List bytes, final int offset, final String value) {
  if (offset < 0 || offset > bytes.length - value.length) return false;
  for (var index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) return false;
  }
  return true;
}

bool _hasLrfSignature(final Uint8List bytes, final int offset, final int length) =>
    length >= 8 &&
    offset >= 0 &&
    offset <= bytes.length - length &&
    _hasAscii(bytes, offset, 'L') &&
    bytes[offset + 1] == 0 &&
    _hasAscii(bytes, offset + 2, 'R') &&
    bytes[offset + 3] == 0 &&
    _hasAscii(bytes, offset + 4, 'F') &&
    bytes[offset + 5] == 0 &&
    bytes[offset + 6] == 0 &&
    bytes[offset + 7] == 0;
