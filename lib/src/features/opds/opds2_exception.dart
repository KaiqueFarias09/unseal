import '../../foundation/exceptions/unseal_exception.dart';

/// Base failure of the OPDS 2.0 JSON parser.
///
/// [pointer] holds the JSON pointer (RFC 6901 style, without the leading
/// `#`) of the value that caused the failure when one is known, so hosts
/// can point users at the offending member.
class Opds2Exception extends InvalidBookException {
  /// Creates an OPDS 2.0 failure with an optional JSON pointer.
  const Opds2Exception(super.message, {this.pointer});

  /// JSON pointer of the offending value, when known.
  final String? pointer;

  @override
  String toString() {
    final location = pointer == null ? '' : ' at $pointer';

    return 'Opds2Exception: $message$location';
  }
}

/// The document is not a well-formed OPDS 2.0 JSON document: broken or
/// truncated JSON, a required member missing, a value of the wrong type,
/// or a normative requirement the official schema does not enforce.
class Opds2MalformedException extends Opds2Exception {
  /// Creates a malformed-document failure.
  const Opds2MalformedException(super.message, {super.pointer});
}

/// Input crossed a declared `Opds2Limits` bound. Limits are checked before
/// the corresponding output is allocated; raising them is the caller's
/// explicit decision.
class Opds2LimitExceededException extends Opds2Exception {
  /// Creates an exceeded-limit failure.
  const Opds2LimitExceededException(super.message, {super.pointer});
}
