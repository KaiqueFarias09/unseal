/// Identity inputs and content digests of the search index.
///
/// The digest helpers implement the shared campaign contract exactly as
/// specified (C02): SHA-256 over UTF-16 little-endian code units, no
/// BOM, no normalization — including any lone surrogates the text
/// carries. They are **temporary adapters**: the campaign's common
/// snapshot contract (A01's P0, `lib/src/foundation/text/`) owns the
/// single implementation of revisions and validation. Once that commit
/// is reviewed into the integration branch, these helpers and the
/// identity record are replaced by the shared types, and the fixed
/// vectors of `test/tests/search/index_identity_test.dart` must still
/// hold byte-for-byte.
library;

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../../foundation/entities/book/reading_order_item.dart';

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

/// The SHA-256 hex digest of [text] as UTF-16 little-endian code units
/// (no BOM, no normalization, lone surrogates preserved) — the
/// `textRevision` of the shared contract.
String textRevisionOf(final String text) {
  final units = text.codeUnits;
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes[i * 2] = units[i] & 0xFF;
    bytes[i * 2 + 1] = (units[i] >> 8) & 0xFF;
  }

  return _sha256Hex(bytes);
}

/// The SHA-256 hex digest of a reading order, per the shared contract:
/// the compact JSON of the ordered `[[resourcePath, isHtml], ...]`
/// array, hashed as UTF-16LE. Array position identifies the occurrence;
/// duplicated paths stay distinct entries.
String readingOrderRevisionOf(final List<ReadingOrderItem> order) {
  final compact = convert.json.encode(<Object?>[
    for (final item in order) <Object?>[item.name, item.isHtml],
  ]);

  return textRevisionOf(compact);
}

String _sha256Hex(final Uint8List bytes) {
  final digest = SHA256Digest().process(bytes);
  final buffer = StringBuffer();
  for (final byte in digest) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }

  return buffer.toString();
}
