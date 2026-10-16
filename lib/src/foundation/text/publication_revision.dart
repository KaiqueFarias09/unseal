import 'revision_digest.dart';

/// How much the parser could verify about the exact source bytes a
/// snapshot's identity claims.
enum SourceEvidence {
  /// No source revision is known. The snapshot works in memory; export
  /// for automatic reuse fails instead of pretending otherwise.
  unverified,

  /// A host-supplied opaque revision in the host's declared namespace.
  /// The parser treats it as a claim that may only be reused against a
  /// context that repeats the same claim — never as a verified hash.
  host,

  /// `sourceRevision` is the parser-computed `sha256:` digest of the
  /// complete original file.
  sha256,
}

/// The logical identity and exact revision of one publication.
///
/// Identity and revision are different pieces of information: the
/// opaque, namespaced [publicationId] says which logical work this is,
/// while [editionId] and [sourceRevision] say which bytes of it. Title,
/// ISBN, file name, path or a prefix hash prove nothing about revision;
/// unknown identity stays unknown rather than inferred.
final class PublicationRevision {
  /// Creates a revision record; [ArgumentError] reports contract
  /// violations.
  ///
  /// [publicationId] must be namespaced (`namespace:value`, no
  /// whitespace) and stays opaque to the parser. [sourceRevision] is
  /// required for [SourceEvidence.sha256] — where it must carry the
  /// exact `sha256:<64 hex>` shape [RevisionDigest] produces — and for
  /// [SourceEvidence.host], where it must carry the host's declared
  /// namespace instead of masquerading as a parser hash. Unverified
  /// revisions carry no source revision at all.
  PublicationRevision({
    required this.publicationId,
    this.editionId,
    this.sourceRevision,
    this.sourceEvidence = SourceEvidence.unverified,
  }) {
    if (!_isNamespacedId(publicationId)) {
      throw ArgumentError.value(
        publicationId,
        'publicationId',
        'Must be a non-empty namespaced id (namespace:value, no whitespace)',
      );
    }
    if (editionId != null && editionId!.isEmpty) {
      throw ArgumentError.value(editionId, 'editionId', 'Must be null or non-empty');
    }
    switch (sourceEvidence) {
      case SourceEvidence.unverified:
        if (sourceRevision != null) {
          throw ArgumentError(
            'An unverified revision carries no sourceRevision; the evidence '
            'kinds are mutually exclusive',
          );
        }
      case SourceEvidence.host:
        if (sourceRevision == null || !_isNamespacedId(sourceRevision!)) {
          throw ArgumentError.value(
            sourceRevision,
            'sourceRevision',
            'Host evidence requires a namespaced revision (namespace:value)',
          );
        }
        if (sourceRevision!.startsWith('sha256:')) {
          throw ArgumentError.value(
            sourceRevision,
            'sourceRevision',
            'Host evidence cannot claim the parser-verified sha256 namespace',
          );
        }
      case SourceEvidence.sha256:
        if (sourceRevision == null || !isSha256Revision(sourceRevision!)) {
          throw ArgumentError.value(
            sourceRevision,
            'sourceRevision',
            'sha256 evidence requires the exact sha256:<64 lowercase hex> shape',
          );
        }
    }
  }

  /// The opaque logical identity, namespaced by whoever mints it
  /// (a host id, a catalog, a library collection).
  final String publicationId;

  /// Which edition of the work this is, when the host knows.
  final String? editionId;

  /// The exact source revision, shaped per [sourceEvidence]; null when
  /// unverified.
  final String? sourceRevision;

  /// What verified [sourceRevision].
  final SourceEvidence sourceEvidence;

  /// Whether two revision records describe the same identity and
  /// revision, comparing every field including explicit nulls.
  bool sameRevision(final PublicationRevision other) {
    return publicationId == other.publicationId &&
        editionId == other.editionId &&
        sourceRevision == other.sourceRevision &&
        sourceEvidence == other.sourceEvidence;
  }

  @override
  bool operator ==(final Object other) => other is PublicationRevision && sameRevision(other);

  @override
  int get hashCode => Object.hash(publicationId, editionId, sourceRevision, sourceEvidence);

  @override
  String toString() =>
      'PublicationRevision($publicationId, edition: $editionId, '
      'source: $sourceRevision, evidence: ${sourceEvidence.name})';
}

/// Whether [value] is a non-empty `namespace:value` id with no
/// whitespace — the shape every opaque identity in the text contract
/// carries.
bool _isNamespacedId(final String value) {
  if (value.isEmpty) return false;
  final separator = value.indexOf(':');
  if (separator <= 0 || separator == value.length - 1) return false;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit == 0x20 || (unit >= 0x09 && unit <= 0x0D)) return false;
  }

  return true;
}
