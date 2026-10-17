import '../../exceptions/pdf_exception.dart';

/// A typed failure raised by the JPEG 2000 codec. Corrupt or hostile
/// codestreams normalize to this at the codec boundary; the PDF
/// adapter decides the documented degradation.
final class JpxException extends PdfException {
  /// Creates the failure with a message safe to surface.
  const JpxException(super.message);
}

/// The codestream parses but uses a JPEG 2000 feature outside the
/// supported Part 1 subset (alpha, palette, CMYK, other precisions,
/// Part 2 extensions, HTJ2K). Never raised for corrupt input — that is
/// [JpxException] — and never turned into invented pixels.
final class JpxUnsupportedException extends JpxException {
  /// Creates the unsupported-feature failure naming the feature.
  const JpxUnsupportedException(super.message);
}
