import 'dart:typed_data';

import 'package:e_livre/src/foundation/utils/image_sniffer.dart';

/// A KF8 `CONT` image container record.
///
/// When active, `CRES` payloads belong to an image container: the
/// first 12 bytes of each `CRES` record are skipped and the remaining
/// data must sniff as an image (EXTH record 539 `application/image`).
class MobiContainer {
  /// Parses a `CONT` record.
  MobiContainer(final Uint8List data) {
    var imageContainer = false;
    if (data.length > 60 &&
        data[48] == 0x45 &&
        data[49] == 0x58 &&
        data[50] == 0x54 &&
        data[51] == 0x48) {
      final view = ByteData.sublistView(data);
      final length = view.getUint32(52);
      var pos = 60;
      while (pos < 60 + length - 8 && pos + 8 <= data.length) {
        final idx = view.getUint32(pos);
        final size = view.getUint32(pos + 4);
        pos += 8;
        final payloadSize = size - 8;
        if (payloadSize < 0) {
          break;
        }
        if (idx == 539) {
          imageContainer = _isMimeImage(data, pos, payloadSize);
          break;
        }
        pos += payloadSize;
      }
    }
    isImageContainer = imageContainer;
  }

  /// Whether this container holds `application/image` resources.
  late final bool isImageContainer;

  /// Number of resources loaded so far.
  int resourceIndex = 0;

  /// Loads a `CRES` payload, unwrapping image containers.
  ///
  /// Returns the image bytes when the payload is a valid image,
  /// otherwise `null`.
  Uint8List? loadImage(final Uint8List data) {
    resourceIndex += 1;
    if (isImageContainer) {
      if (data.length <= 12) {
        return null;
      }
      final unwrapped = Uint8List.sublistView(data, 12);
      return sniffImageType(unwrapped) != null ? unwrapped : null;
    }
    return null;
  }

  static bool _isMimeImage(final Uint8List data, final int start, final int length) {
    const mime = 'application/image';
    if (length != mime.length) {
      return false;
    }
    for (var i = 0; i < mime.length; i++) {
      if (data[start + i] != mime.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }
}
