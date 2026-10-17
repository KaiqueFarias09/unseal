import 'publication_revision.dart';
import 'revision_digest.dart';
import 'section_occurrence.dart';
import 'text_profile.dart';

/// The current canonical-text snapshot schema. Codec payloads carry
/// it; a different value is a revision mismatch, not a best-effort
/// decode.
const int canonicalTextSchemaVersion = 1;

/// The canonical text of one section occurrence, captured explicitly
/// over materialized text and bound to the identity that produced it.
///
/// The persistent identity is the tuple (schemaVersion, publicationId,
/// editionId, sourceRevision, sourceEvidence, readingOrderRevision,
/// sectionIndex, resourcePath, textProfileId, textRevision);
/// [sameIdentity] compares every field including explicit nulls.
/// Object identity or an equal text digest alone never certify the
/// same edition.
final class CanonicalTextSnapshot {
  /// Captures a snapshot over [text] materialized from [occurrence]
  /// under [profile], computing [textRevision] from the exact UTF-16
  /// code units — no BOM, no normalization, isolated surrogates
  /// preserved.
  CanonicalTextSnapshot({
    required this.identity,
    required this.occurrence,
    required this.profile,
    required this.text,
  }) : textRevision = RevisionDigest.textRevision(text) {
    if (text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Canonical text snapshots carry non-empty text');
    }
  }

  /// The publication identity and source revision this text came from.
  final PublicationRevision identity;

  /// Which section occurrence of the publication the text belongs to.
  final SectionOccurrence occurrence;

  /// The extraction profile that produced the text.
  final TextProfile profile;

  /// The canonical text, in UTF-16 code units.
  final String text;

  /// The `sha256:` digest of [text]'s UTF-16LE bytes.
  final String textRevision;

  /// The schema version this snapshot's persistent identity uses.
  int get schemaVersion => canonicalTextSchemaVersion;

  /// The text's length in UTF-16 code units — the offset unit every
  /// range on this snapshot uses.
  int get utf16Length => text.length;

  /// Whether both snapshots share the full persistent identity tuple:
  /// schema, publication identity and revision, occurrence, profile
  /// and text revision, every field compared including explicit nulls.
  bool sameIdentity(final CanonicalTextSnapshot other) {
    return schemaVersion == other.schemaVersion &&
        identity.sameRevision(other.identity) &&
        occurrence.sameOccurrence(other.occurrence) &&
        profile.sameProfile(other.profile) &&
        textRevision == other.textRevision;
  }

  /// The persistent identity as one opaque string — a stable key for
  /// hosts that index snapshots, derived from the same tuple
  /// [sameIdentity] compares.
  String get identityKey {
    return RevisionDigest.encodeCompactJson(<String, Object?>{
      'schemaVersion': schemaVersion,
      'publicationId': identity.publicationId,
      'editionId': identity.editionId,
      'sourceRevision': identity.sourceRevision,
      'sourceEvidence': identity.sourceEvidence.name,
      'readingOrderRevision': occurrence.readingOrderRevision,
      'sectionIndex': occurrence.sectionIndex,
      'resourcePath': occurrence.resourcePath,
      'textProfileId': profile.id,
      'textRevision': textRevision,
    });
  }

  /// Whether the snapshot carries everything verified reuse requires:
  /// a source revision with its evidence and a known reading order
  /// revision. In-memory-only snapshots answer false and refuse
  /// export instead of inventing identity.
  bool get isExportable =>
      identity.sourceRevision != null && occurrence.readingOrderRevision != null;

  @override
  String toString() =>
      'CanonicalTextSnapshot(${identityKey.substring(0, 60)}…, '
      'length: $utf16Length)';
}
