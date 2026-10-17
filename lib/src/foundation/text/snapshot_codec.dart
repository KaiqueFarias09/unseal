import '../exceptions/unseal_exception.dart';
import 'canonical_text_range.dart';
import 'canonical_text_snapshot.dart';
import 'publication_revision.dart';
import 'section_occurrence.dart';
import 'text_profile.dart';

/// The snapshot payload was malformed: wrong shape, unknown schema,
/// a digest that does not match the text it claims, or an identity
/// too incomplete to export. Hostile codec input normalizes here —
/// `RangeError` or `FormatException` from the JSON layer never leaks.
final class CanonicalTextCodecException extends UnsealException {
  /// Creates the exception with the reason the payload or snapshot was
  /// refused.
  const CanonicalTextCodecException(super.message);
}

/// A snapshot (or range) is real but does not describe the destination
/// it was offered to: different schema, publication revision,
/// occurrence, reading order, extraction profile or text revision.
/// Confirmed incompatibility is a mismatch, never a silent reuse and
/// never a silent drop.
final class IncompatibleRevisionException extends UnsealException {
  /// Creates the exception naming the destination mismatch.
  const IncompatibleRevisionException(super.message);
}

/// The one codec for the common text contract: it preserves the full
/// identity tuple, revalidates every digest against the carried text
/// and refuses reuse a destination context cannot confirm.
///
/// Export requires an exportable identity — a source revision with its
/// evidence and a known reading order revision. In-memory-only
/// snapshots fail the export explicitly rather than travel with
/// invented identity. Import re-runs the same constructor validation,
/// recomputes `textRevision` from the carried text and the profile id
/// from the carried profile parts, and [verifyCompatible] confirms the
/// imported claims against the destination snapshot: a carried claim
/// is an allegation, not proof.
abstract final class CanonicalTextCodec {
  const CanonicalTextCodec._();

  /// Encodes [snapshot] into a structured-clone-safe payload.
  ///
  /// Throws [CanonicalTextCodecException] when [snapshot] lacks an
  /// exportable identity.
  static Map<String, Object?> encode(final CanonicalTextSnapshot snapshot) {
    if (!snapshot.isExportable) {
      throw const CanonicalTextCodecException(
        'Snapshot identity is incomplete (unverified source or unknown '
        'reading order); export for automatic reuse fails instead of '
        'inventing identity',
      );
    }

    return <String, Object?>{
      'schemaVersion': snapshot.schemaVersion,
      'publication': <String, Object?>{
        'publicationId': snapshot.identity.publicationId,
        'editionId': snapshot.identity.editionId,
        'sourceRevision': snapshot.identity.sourceRevision,
        'sourceEvidence': snapshot.identity.sourceEvidence.name,
      },
      'occurrence': <String, Object?>{
        'sectionIndex': snapshot.occurrence.sectionIndex,
        'resourcePath': snapshot.occurrence.resourcePath,
        'readingOrderRevision': snapshot.occurrence.readingOrderRevision,
      },
      'profile': <String, Object?>{
        'id': snapshot.profile.id,
        'algorithm': snapshot.profile.algorithm,
        'options': <String, Object?>{
          for (final e in snapshot.profile.options.entries) e.key: e.value,
        },
        'planRevision': snapshot.profile.planRevision,
      },
      'textRevision': snapshot.textRevision,
      'text': snapshot.text,
    };
  }

  /// Decodes a payload [encode] produced, revalidating every field:
  /// schema version, value shapes, the text digest recomputed from the
  /// carried text and the profile id recomputed from the carried
  /// parts. Throws [CanonicalTextCodecException] on any inconsistency.
  static CanonicalTextSnapshot decode(final Object? payload) {
    if (payload is! Map<Object?, Object?>) {
      throw const CanonicalTextCodecException('Snapshot payload must be a JSON object');
    }
    final map = _stringKeyMap(payload, 'payload');

    final schemaVersion = map['schemaVersion'];
    if (schemaVersion != canonicalTextSchemaVersion) {
      throw CanonicalTextCodecException(
        'Snapshot schema version ${schemaVersion ?? 'missing'} is not '
        '$canonicalTextSchemaVersion; refusing a best-effort decode',
      );
    }

    final publication = _child(map, 'publication');
    final occurrence = _child(map, 'occurrence');
    final profile = _child(map, 'profile');
    final text = map['text'];
    final textRevision = map['textRevision'];
    if (text is! String || text.isEmpty) {
      throw const CanonicalTextCodecException('Snapshot text must be a non-empty string');
    }
    if (textRevision is! String) {
      throw const CanonicalTextCodecException('Snapshot textRevision must be a string');
    }

    final snapshot = CanonicalTextSnapshot(
      identity: _decodePublication(publication),
      occurrence: _decodeOccurrence(occurrence),
      profile: _decodeProfile(profile),
      text: text,
    );
    if (snapshot.textRevision != textRevision) {
      throw const CanonicalTextCodecException(
        'Carried textRevision does not match the digest of the carried text',
      );
    }

    return snapshot;
  }

  /// Confirms an imported [candidate] against the [target] context it
  /// will be reused under: every identity field must match, including
  /// explicit nulls. A carried verification flag is an allegation; the
  /// destination confirms it or the reuse fails with
  /// [IncompatibleRevisionException].
  static void verifyCompatible(
    final CanonicalTextSnapshot candidate,
    final CanonicalTextSnapshot target,
  ) {
    if (!candidate.sameIdentity(target)) {
      throw IncompatibleRevisionException(
        'Snapshot identity does not match the destination '
        '(candidate ${candidate.identityKey} vs target ${target.identityKey})',
      );
    }
  }

  /// Encodes a range together with its bound snapshot.
  static Map<String, Object?> encodeRange(final CanonicalTextRange range) {
    return <String, Object?>{
      'snapshot': encode(range.snapshot),
      'start': range.start,
      'end': range.end,
    };
  }

  /// Decodes a range payload, rebuilding and revalidating the bound
  /// snapshot first; the range constructor then re-checks the bounds
  /// against the decoded text.
  static CanonicalTextRange decodeRange(final Object? payload) {
    if (payload is! Map<Object?, Object?>) {
      throw const CanonicalTextCodecException('Range payload must be a JSON object');
    }
    final map = _stringKeyMap(payload, 'payload');
    final snapshot = decode(map['snapshot']);
    final start = map['start'];
    final end = map['end'];
    if (start is! int || end is! int) {
      throw const CanonicalTextCodecException('Range bounds must be integers');
    }

    return CanonicalTextRange(snapshot: snapshot, start: start, end: end);
  }

  static PublicationRevision _decodePublication(final Map<String, Object?> map) {
    final evidence = map['sourceEvidence'];
    if (evidence is! String) {
      throw const CanonicalTextCodecException('Snapshot sourceEvidence must be a string');
    }
    final known = SourceEvidence.values.where((final value) => value.name == evidence).toList();
    if (known.length != 1) {
      throw CanonicalTextCodecException('Unknown sourceEvidence "$evidence"');
    }
    final publicationId = map['publicationId'];
    if (publicationId is! String) {
      throw const CanonicalTextCodecException('Snapshot publicationId must be a string');
    }
    final sourceRevision = map['sourceRevision'];
    if (sourceRevision != null && sourceRevision is! String) {
      throw const CanonicalTextCodecException('Snapshot sourceRevision must be a string or null');
    }
    final editionId = map['editionId'];
    if (editionId != null && editionId is! String) {
      throw const CanonicalTextCodecException('Snapshot editionId must be a string or null');
    }
    final source = sourceRevision as String?;
    final edition = editionId as String?;

    try {
      return PublicationRevision(
        publicationId: publicationId,
        editionId: edition,
        sourceRevision: source,
        sourceEvidence: known.single,
      );
    } on ArgumentError catch (error) {
      throw CanonicalTextCodecException('Snapshot publication identity is invalid: $error');
    }
  }

  static SectionOccurrence _decodeOccurrence(final Map<String, Object?> map) {
    final sectionIndex = map['sectionIndex'];
    if (sectionIndex is! int) {
      throw const CanonicalTextCodecException('Snapshot sectionIndex must be an integer');
    }
    final resourcePath = map['resourcePath'];
    if (resourcePath is! String) {
      throw const CanonicalTextCodecException('Snapshot resourcePath must be a string');
    }
    final readingOrderRevision = map['readingOrderRevision'];
    if (readingOrderRevision != null && readingOrderRevision is! String) {
      throw const CanonicalTextCodecException(
        'Snapshot readingOrderRevision must be a string or null',
      );
    }
    final order = readingOrderRevision as String?;

    try {
      return SectionOccurrence(
        sectionIndex: sectionIndex,
        resourcePath: resourcePath,
        readingOrderRevision: order,
      );
    } on ArgumentError catch (error) {
      throw CanonicalTextCodecException('Snapshot occurrence is invalid: $error');
    }
  }

  static TextProfile _decodeProfile(final Map<String, Object?> map) {
    final algorithm = map['algorithm'];
    final planRevision = map['planRevision'];
    final id = map['id'];
    final optionsValue = map['options'];
    if (algorithm is! String || planRevision is! String || id is! String) {
      throw const CanonicalTextCodecException('Snapshot profile parts must be strings');
    }
    if (optionsValue is! Map<Object?, Object?>) {
      throw const CanonicalTextCodecException('Snapshot profile options must be an object');
    }
    final options = <String, String>{};
    for (final entry in optionsValue.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const CanonicalTextCodecException('Profile options must map strings to strings');
      }
      options[entry.key as String] = entry.value as String;
    }

    final rebuilt = TextProfile.of(
      algorithm: algorithm,
      options: options,
      planRevision: planRevision,
    );
    if (rebuilt.id != id) {
      throw const CanonicalTextCodecException(
        'Carried profile id does not match the digest of the carried parts',
      );
    }

    return rebuilt;
  }

  static Map<String, Object?> _child(final Map<String, Object?> map, final String key) {
    final value = map[key];
    if (value is! Map) {
      throw CanonicalTextCodecException('Snapshot $key must be a JSON object');
    }

    return _stringKeyMap(value, key);
  }

  static Map<String, Object?> _stringKeyMap(final Map<Object?, Object?> map, final String field) {
    final out = <String, Object?>{};
    for (final entry in map.entries) {
      if (entry.key is! String) {
        throw CanonicalTextCodecException('Snapshot $field keys must be strings');
      }
      out[entry.key as String] = entry.value;
    }

    return out;
  }
}
