import 'dart:typed_data';

import '../../exceptions/pdf_exception.dart';
import '../../header/pdf_document.dart';
import '../../header/pdf_object.dart';
import '../pdf_stream_decoder.dart';
import 'jpx_decoder.dart';
import 'jpx_exception.dart';

/// The stream is handed to the JPEG 2000 codec after every earlier
/// filter (typically `/ASCII85Decode`) has run.
const String kPdfFilterJpxDecode = 'JPXDecode';

/// Decodes a `/JPXDecode` image stream to samples with typed failures:
/// corrupt codestreams, PDF/codestream geometry or colorspace
/// conflicts and out-of-subset features raise `JpxException` /
/// `JpxUnsupportedException` (both `PdfException`).
JpxImage decodePdfJpxSamples(final PdfDocument document, final PdfStream stream) {
  final smaskInData = document.resolve(stream.dictionary['SMaskInData'] ?? const PdfNull());
  if (smaskInData is! PdfNull) {
    if (smaskInData is! PdfNumber || !smaskInData.isInteger) {
      throw const JpxException('JPXDecode /SMaskInData must be an integer.');
    }
    if (smaskInData.intValue != 0) {
      throw const JpxUnsupportedException(
        'JPXDecode /SMaskInData alpha channels are not supported.',
      );
    }
  }
  final data = decodePdfStreamBeforeImageCodec(stream, document.resolve, kPdfFilterJpxDecode);
  final image = decodeJpxImage(data);
  _validatePdfColorSpace(document, stream, image.componentCount);
  _validatePdfDimensions(document, stream, image.width, image.height);
  return image;
}

/// Decodes a `/JPXDecode` image stream to a grayscale or truecolor
/// PNG, or null when the codec rejects the stream — the documented
/// geometry-only degradation every unsupported image uses.
(Uint8List, String)? decodePdfJpxImage(final PdfDocument document, final PdfStream stream) {
  try {
    final image = decodePdfJpxSamples(document, stream);
    return (image.toPngBytes(), 'png');
  } on PdfException {
    return null;
  }
}

/// An explicit PDF `/ColorSpace` must agree with the codestream's
/// component count; palettes, CMYK and separation spaces stay outside
/// the subset and reject instead of inventing pixels.
void _validatePdfColorSpace(
  final PdfDocument document,
  final PdfStream stream,
  final int componentCount,
) {
  final object = document.resolve(
    stream.dictionary['ColorSpace'] ?? stream.dictionary['CS'] ?? const PdfNull(),
  );
  final familyInfo = _colorSpaceFamily(document, object);
  if (familyInfo == null) {
    return; // No colorspace: the codestream declaration rules.
  }
  final (family, components) = familyInfo;
  if (components == null) {
    throw JpxUnsupportedException('PDF /$family color spaces are not supported with JPXDecode.');
  }
  if (components != componentCount) {
    throw JpxException(
      'PDF /$family colorspace needs $components components but the '
      'JPEG 2000 codestream has $componentCount.',
    );
  }
}

/// Returns the colorspace family name and its component count, or
/// `(family, null)` for out-of-subset families; null when the stream
/// declares no colorspace.
(String, int?)? _colorSpaceFamily(final PdfDocument document, final PdfObject? object) {
  if (object is PdfName) {
    switch (object.value) {
      case 'DeviceGray':
      case 'G':
        return ('DeviceGray', 1);
      case 'DeviceRGB':
      case 'RGB':
        return ('DeviceRGB', 3);
      case 'DeviceCMYK':
      case 'CMYK':
        throw const JpxUnsupportedException(
          'PDF /DeviceCMYK color spaces are not supported with JPXDecode.',
        );
      case 'Pattern':
        throw const JpxUnsupportedException(
          'PDF /Pattern color spaces are not supported with JPXDecode.',
        );
      default:
        throw JpxUnsupportedException(
          'PDF /${object.value} color spaces are not supported with '
          'JPXDecode.',
        );
    }
  }
  if (object is PdfArray && object.items.isNotEmpty) {
    final family = document.resolve(object.items[0]);
    if (family is PdfName) {
      switch (family.value) {
        case 'ICCBased':
        case 'CalGray':
        case 'CalRGB':
          throw JpxUnsupportedException(
            'PDF /${family.value} color conversion is not supported with JPXDecode.',
          );
        case 'Indexed':
        case 'I':
          throw const JpxUnsupportedException(
            'PDF /Indexed palettes are not supported with JPXDecode.',
          );
        case 'Separation':
        case 'DeviceN':
        case 'Lab':
          throw JpxUnsupportedException(
            'PDF /${family.value} color spaces are not supported with '
            'JPXDecode.',
          );
      }
    }
  }
  throw const JpxException('PDF colorspace object is malformed.');
}

/// A PDF `/Width` or `/Height` that disagrees with the codestream
/// rejects the image (JPXDecode carries its own authoritative
/// geometry).
void _validatePdfDimensions(
  final PdfDocument document,
  final PdfStream stream,
  final int width,
  final int height,
) {
  final declaredWidth = _pdfDimension(document, stream, 'Width', 'W');
  final declaredHeight = _pdfDimension(document, stream, 'Height', 'H');
  if ((declaredWidth > 0 && declaredWidth != width) ||
      (declaredHeight > 0 && declaredHeight != height)) {
    throw JpxException(
      'PDF declares ${declaredWidth}x$declaredHeight but the JPEG 2000 '
      'codestream decodes to ${width}x$height.',
    );
  }
}

int _pdfDimension(
  final PdfDocument document,
  final PdfStream stream,
  final String long,
  final String short,
) {
  final value = document.resolve(
    stream.dictionary[long] ?? stream.dictionary[short] ?? const PdfNull(),
  );
  if (value is PdfNumber) return value.intValue;
  return 0;
}
