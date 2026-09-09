import '../../../foundation/exceptions/elivre_exception.dart';

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

/// Thrown when a PDF document is encrypted and the supplied
/// (or empty) password does not open it.
///
/// The fields tell a host how to prompt: [requiresNonEmptyPassword]
/// is true when the document needs a real password (an empty one
/// failed) and false when a wrong password was tried against a file
/// that opens with none; [permissions] carries the `/P` flags of the
/// encryption dictionary. A successful open with only the owner
/// password parses normally — the library does **not** enforce the
/// permission bits.
class PdfEncryptedException extends PdfException {
  /// Creates a [PdfEncryptedException] for a document that requires
  /// a password ([requiresNonEmptyPassword]) with the encryption
  /// dictionary's [permissions] flags.
  const PdfEncryptedException({this.requiresNonEmptyPassword = true, this.permissions = 0xFFFFFFFF})
    : super(
        requiresNonEmptyPassword
            ? 'PDF document is encrypted and requires a password.'
            : 'PDF document is encrypted and the supplied password is '
                  'incorrect.',
      );

  /// Whether a non-empty password must be supplied (an empty one
  /// failed to authenticate). `false` means a non-empty password was
  /// tried and rejected on a document that opened without one.
  final bool requiresNonEmptyPassword;

  /// The encryption dictionary's `/P` permission flags — the bits
  /// the *reader* may enforce after a successful open (printing,
  /// copying, ...); this library exposes them but does not enforce
  /// them.
  final int permissions;

  @override
  String toString() => 'PdfEncryptedException: $message';
}
