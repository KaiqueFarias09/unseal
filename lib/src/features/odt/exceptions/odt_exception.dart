import '../../../foundation/exceptions/unseal_exception.dart';

/// Base error for an OpenDocument Text package that cannot be read.
class OdtException extends UnsealException {
  /// Creates an [OdtException].
  const OdtException(super.message);

  @override
  String toString() => 'OdtException: $message';
}

/// Thrown when the input is not a readable ODT ZIP package.
class InvalidOdtPackageException extends OdtException {
  /// Creates an [InvalidOdtPackageException].
  const InvalidOdtPackageException(super.message);

  @override
  String toString() => 'InvalidOdtPackageException: $message';
}

/// Thrown when the required ODT content part is missing.
class MissingOdtPartException extends OdtException {
  /// Creates an exception for the missing [part].
  const MissingOdtPartException(this.part) : super('ODT package is missing required part "$part".');

  /// The normalized part path that was required.
  final String part;

  @override
  String toString() => 'MissingOdtPartException: $message';
}

/// Thrown when the ODT content XML is malformed.
class InvalidOdtXmlException extends OdtException {
  /// Creates an exception for [part] and its [details].
  const InvalidOdtXmlException(this.part, this.details)
    : super('ODT part "$part" contains invalid XML: $details');

  /// The part whose XML could not be consumed.
  final String part;

  /// Human-readable parse details.
  final String details;

  @override
  String toString() => 'InvalidOdtXmlException: $message';
}
