import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';

/// Thrown when a PDF document cannot be parsed.
///
/// Structure problems that leave the document unusable (no pages,
/// unreadable cross-reference after the scan fallback) surface here;
/// per-page extraction problems degrade silently instead.
class PdfException extends ELivreException {
  /// Creates a [PdfException] with the given [message].
  const PdfException(super.message);

  @override
  String toString() => 'PdfException: $message';
}

/// Thrown when the PDF document is encrypted.
///
/// Password-protected documents stay outside the supported set until
/// a decrypt callback exists; unencrypted permission-restricted files
/// also carry `/Encrypt` and are rejected alike.
class PdfEncryptedException extends PdfException {
  /// Creates a [PdfEncryptedException].
  const PdfEncryptedException()
    : super('PDF document is encrypted; encrypted documents are not supported.');

  @override
  String toString() => 'PdfEncryptedException: $message';
}
