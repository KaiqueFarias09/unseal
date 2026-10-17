/// Identity inputs and content digests of the search index.
///
/// The digest helpers delegate to the shared campaign contract's single
/// implementation (C02, `lib/src/foundation/text/revision_digest.dart`):
/// SHA-256 over UTF-16 little-endian code units, no BOM, no
/// normalization — including any lone surrogates the text carries. The
/// fixed vectors of `test/tests/search/index_serialization_test.dart`
/// still hold byte-for-byte. `SearchIndexIdentity` remains the index's
/// own identity record; its unification with the shared
/// `PublicationRevision` is the index campaign's integration decision.
library;

import '../../../foundation/entities/book/reading_order_item.dart';
import '../../../foundation/text/revision_digest.dart';

/// Where a publication's revision evidence comes from. Free-form host
/// claims are *allegations*: an import re-checks the content digests it
/// can verify and never upgrades evidence on its own.
enum SearchSourceEvidence {
  /// No verified revision evidence. In-memory work is allowed;
  /// automatic reuse demands explicit verification first.
  unverified,

  /// The host application asserts the revision under its own namespace.
  /// A claim, not a parser-verified hash.
  host,

  /// `sourceRevision` carries a `sha256:` hash of the complete original
  /// file.
  sha256,
}

/// Explicit identity inputs binding an index to a publication, per the
/// shared campaign contract. All fields are optional and opaque to the
/// index: unknown identity stays unknown, and nothing here claims that
/// a title, file name or prefix hash proves a revision.
final class SearchIndexIdentity {
  /// Creates identity inputs; pass only what is actually known.
  const SearchIndexIdentity({
    this.publicationId,
    this.editionId,
    this.sourceRevision,
    this.sourceEvidence = SearchSourceEvidence.unverified,
  });

  /// Opaque logical identity, namespaced by the host (`ns:value`).
  final String? publicationId;

  /// Optional edition within the publication.
  final String? editionId;

  /// Optional exact revision: a `sha256:` hash of the complete source
  /// file, or a host-declared revision that carries its own namespace
  /// and non-reuse guarantee.
  final String? sourceRevision;

  /// What backs [sourceRevision].
  final SearchSourceEvidence sourceEvidence;

  /// The wire map of the identity fields.
  Map<String, Object?> toWire() {
    return <String, Object?>{
      'publicationId': publicationId,
      'editionId': editionId,
      'sourceRevision': sourceRevision,
      'sourceEvidence': sourceEvidence.name,
    };
  }

  /// Rebuilds identity from its wire map; null for an absent entry.
  static SearchIndexIdentity? fromWire(final Object? wire) {
    if (wire == null) return null;
    if (wire is! Map<String, Object?>) {
      throw const FormatException('searchIndex identity must be an object.');
    }
    final evidenceName = wire['sourceEvidence'];
    final evidence = evidenceName == null
        ? SearchSourceEvidence.unverified
        : SearchSourceEvidence.values.firstWhere(
            (final value) => value.name == evidenceName,
            orElse: () => throw const FormatException(
              'searchIndex identity carries an unknown sourceEvidence.',
            ),
          );

    return SearchIndexIdentity(
      publicationId: _optionalString(wire['publicationId'], 'publicationId'),
      editionId: _optionalString(wire['editionId'], 'editionId'),
      sourceRevision: _optionalString(wire['sourceRevision'], 'sourceRevision'),
      sourceEvidence: evidence,
    );
  }

  /// Whether two identities agree on every present field. An absent
  /// field is not a wildcard: present versus absent is a mismatch.
  bool isCompatibleWith(final SearchIndexIdentity other) {
    return publicationId == other.publicationId &&
        editionId == other.editionId &&
        sourceRevision == other.sourceRevision &&
        sourceEvidence == other.sourceEvidence;
  }
}

String? _optionalString(final Object? value, final String field) {
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('searchIndex identity field $field must be a string.');
  }

  return value;
}

/// The `sha256:`-prefixed digest of [text]'s UTF-16 little-endian code
/// units (no BOM, no normalization, lone surrogates preserved) — the
/// shared contract's `textRevision`, delegated to its single
/// implementation.
String textRevisionOf(final String text) => RevisionDigest.textRevision(text);

/// The SHA-256 digest of a reading order, per the shared contract:
/// the compact JSON of the ordered `[[resourcePath, isHtml], ...]`
/// array, hashed as UTF-16LE. Array position identifies the occurrence;
/// duplicated paths stay distinct entries.
String readingOrderRevisionOf(final List<ReadingOrderItem> order) {
  return RevisionDigest.readingOrderRevision([
    for (final item in order) (item.name, item.isHtml),
  ]);
}
