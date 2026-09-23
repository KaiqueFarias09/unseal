import 'dart:typed_data';

/// Returns whether [bytes] has the LRX2 ISO base media file type signature.
bool hasLrx2Signature(final Uint8List bytes) {
  const signature = <int>[0x66, 0x74, 0x79, 0x70, 0x4c, 0x52, 0x58, 0x32];
  return bytes.length >= 12 && _matches(bytes, 4, signature);
}

/// Returns whether [bytes] has the legacy LRX signature.
bool hasLegacyLrxSignature(final Uint8List bytes) {
  const signature = <int>[0x4c, 0x52, 0x58];
  return bytes.length >= 8 && _matches(bytes, 4, signature);
}

bool _matches(final Uint8List bytes, final int offset, final List<int> signature) {
  if (offset < 0 || offset > bytes.length - signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}
