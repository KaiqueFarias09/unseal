import '../../../foundation/exceptions/unseal_exception.dart';

/// Base error for a DOCX package that cannot be read by unseal.
class DocxException extends UnsealException {
  /// Creates a [DocxException].
  const DocxException(super.message);

  @override
  String toString() => 'DocxException: $message';
}

/// Thrown when the input is not a readable ZIP/Open XML package.
class InvalidDocxPackageException extends DocxException {
  /// Creates an [InvalidDocxPackageException].
  const InvalidDocxPackageException(super.message);

  @override
  String toString() => 'InvalidDocxPackageException: $message';
}

/// Thrown when a required Open XML part is absent from the package.
class MissingDocxPartException extends DocxException {
  /// Creates an exception for the missing [part].
  const MissingDocxPartException(this.part)
    : super('DOCX package is missing required part "$part".');

  /// The normalized part path that was required.
  final String part;

  @override
  String toString() => 'MissingDocxPartException: $message';
}

/// Thrown when a required XML part is malformed or has the wrong root.
class InvalidDocxXmlException extends DocxException {
  /// Creates an exception for [part] and its human-readable [details].
  const InvalidDocxXmlException(this.part, this.details)
    : super('DOCX part "$part" contains invalid XML: $details');

  /// The part whose XML could not be consumed.
  final String part;

  /// A short explanation of the XML failure.
  final String details;

  @override
  String toString() => 'InvalidDocxXmlException: $message';
}
