import 'dart:convert';

import '../../../foundation/exceptions/unseal_exception.dart';
import '../../../foundation/text/publication_revision.dart';
import '../../../foundation/text/revision_digest.dart';
import '../../../foundation/text/section_occurrence.dart';
import '../../../foundation/text/text_profile.dart';
import 'anchor_limits.dart';
import 'annotation_anchor.dart';

/// The anchor payload was malformed: wrong shape, unknown schema
/// version, a field outside its declared bounds, a non-exportable
/// identity, or a key the envelope does not declare. Hostile codec
/// input normalizes here — `FormatException` or `ArgumentError` from
/// the JSON and constructor layers never leaks through the public API.
final class AnchorCodecException extends UnsealException {
  /// Creates the exception with the reason the payload was refused.
  const AnchorCodecException(super.message);
}

/// Encodes [anchor] as a structured-clone-safe payload of primitives.
///
/// The envelope carries the full identity tuple (publication revision,
/// occurrence, profile), the text revision, the UTF-16 bounds and the
/// quote/context evidence — everything a future resolution needs,
/// nothing of the section text itself. Unknown features are impossible
/// by construction: the schema is closed, and decoding rejects keys it
/// does not declare.
///
/// Throws [AnchorCodecException] when [anchor] lacks an exportable
/// identity ([AnnotationAnchor.isExportable] is false): an in-memory
/// anchor fails export explicitly instead of traveling with invented
/// identity.
Map<String, Object?> encodeAnchor(final AnnotationAnchor anchor) {
  if (!anchor.isExportable) {
    throw const AnchorCodecException(
      'Anchor identity is incomplete (unverified source or unknown reading '
      'order); export for automatic reuse fails instead of inventing identity',
    );
  }

  return <String, Object?>{
    'anchorSchemaVersion': anchorSchemaVersion,
    if (anchor.annotationId != null) 'annotationId': anchor.annotationId,
    'identity': <String, Object?>{
      'publicationId': anchor.identity.publicationId,
      'editionId': anchor.identity.editionId,
      'sourceRevision': anchor.identity.sourceRevision,
      'sourceEvidence': anchor.identity.sourceEvidence.name,
    },
    'occurrence': <String, Object?>{
      'sectionIndex': anchor.occurrence.sectionIndex,
      'resourcePath': anchor.occurrence.resourcePath,
      'readingOrderRevision': anchor.occurrence.readingOrderRevision,
    },
    'profile': <String, Object?>{
      'id': anchor.profile.id,
      'algorithm': anchor.profile.algorithm,
      'options': <String, Object?>{
        for (final entry in anchor.profile.options.entries) entry.key: entry.value,
      },
      'planRevision': anchor.profile.planRevision,
    },
    'textRevision': anchor.textRevision,
    'range': <String, Object?>{'start': anchor.start, 'end': anchor.end},
    'quote': <String, Object?>{
      'exact': anchor.quote.exact,
      'before': anchor.quote.before,
      'after': anchor.quote.after,
    },
  };
}

/// Decodes an [encodeAnchor] payload, revalidating every field.
///
/// Accepts the encoded map or its JSON text. The decode re-runs the
/// constructor validation of every identity type (a namespaced
/// publication id, a well-shaped `sha256:` revision, the evidence
/// rules), recomputes the profile id from the carried parts, bounds
/// every string against [limits] and rejects unknown keys and unknown
/// schema versions — a payload another version wrote is never
/// reinterpreted here.
///
/// Every digest a payload carries is an allegation until a resolution
/// confirms it against materialized text; the decode only proves the
/// shapes and internal consistency.
///
/// Throws [AnchorCodecException] on any inconsistency or violation.
AnnotationAnchor decodeAnchor(
  final Object? payload, {
  final AnchorLimits limits = const AnchorLimits(),
}) {
  limits.requireValid();
  final Map<Object?, Object?> raw;
  if (payload is String) {
    if (payload.length > limits.maxPayloadCodeUnits) {
      throw AnchorCodecException(
        'Anchor payload exceeds AnchorLimits.maxPayloadCodeUnits '
        '(${limits.maxPayloadCodeUnits})',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException catch (error) {
      throw AnchorCodecException('Anchor payload is not valid JSON: ${error.message}');
    }
    if (decoded is! Map) {
      throw const AnchorCodecException('Anchor payload must be a JSON object');
    }
    raw = decoded;
  } else if (payload is Map) {
    raw = payload;
  } else {
    throw const AnchorCodecException('Anchor payload must be a JSON object');
  }

  for (final key in raw.keys) {
    if (key is! String) {
      throw const AnchorCodecException('Anchor payload keys must be strings');
    }
  }
  final map = Map<String, Object?>.from(raw);

  final version = map['anchorSchemaVersion'];
  if (version != anchorSchemaVersion) {
    throw AnchorCodecException(
      'Anchor schema version ${version ?? 'missing'} is not '
      '$anchorSchemaVersion; refusing to reinterpret the payload',
    );
  }
  const declaredKeys = {
    'anchorSchemaVersion',
    'annotationId',
    'identity',
    'occurrence',
    'profile',
    'textRevision',
    'range',
    'quote',
  };
  final unknownKeys = map.keys.where((final key) => !declaredKeys.contains(key)).toList();
  if (unknownKeys.isNotEmpty) {
    throw AnchorCodecException('Anchor payload carries undeclared keys: $unknownKeys');
  }

  final annotationId = _optionalString(map['annotationId'], 'annotationId', limits);
  final identity = _decodeIdentity(_child(map, 'identity'), limits);
  final occurrence = _decodeOccurrence(_child(map, 'occurrence'), limits);
  final profile = _decodeProfile(_child(map, 'profile'), limits);

  final textRevision = map['textRevision'];
  if (textRevision is! String || !isSha256Revision(textRevision)) {
    throw const AnchorCodecException('Anchor textRevision must be a sha256:<64 hex> string');
  }

  final range = _child(map, 'range');
  final start = range['start'];
  final end = range['end'];
  if (start is! int || end is! int) {
    throw const AnchorCodecException('Anchor range bounds must be integers');
  }
  if (start < 0 || end < start) {
    throw const AnchorCodecException('Anchor range must satisfy 0 <= start <= end');
  }

  final quoteJson = _child(map, 'quote');
  final exact = _requiredString(quoteJson, 'exact', limits.maxQuoteLength);
  final before = _requiredString(quoteJson, 'before', limits.maxContextLength);
  final after = _requiredString(quoteJson, 'after', limits.maxContextLength);
  if (exact.length != end - start) {
    throw const AnchorCodecException(
      'Anchor quote.exact length must equal the range span; a point anchor '
      'carries an empty exact',
    );
  }

  try {
    return AnnotationAnchor.parts(
      identity: identity,
      occurrence: occurrence,
      profile: profile,
      textRevision: textRevision,
      start: start,
      end: end,
      quote: AnchorQuote(exact: exact, before: before, after: after),
      annotationId: annotationId,
    );
  } on ArgumentError catch (error) {
    throw AnchorCodecException('Anchor payload failed validation: ${error.message}');
  }
}

Map<String, Object?> _child(final Map<String, Object?> map, final String key) {
  final value = map[key];
  if (value is! Map<Object?, Object?>) {
    throw AnchorCodecException('Anchor payload field $key must be an object');
  }

  return Map<String, Object?>.from(value);
}

PublicationRevision _decodeIdentity(final Map<String, Object?> map, final AnchorLimits limits) {
  final evidenceName = map['sourceEvidence'];
  if (evidenceName is! String) {
    throw const AnchorCodecException('Anchor identity must declare sourceEvidence');
  }
  final SourceEvidence evidence;
  switch (evidenceName) {
    case 'unverified':
      evidence = SourceEvidence.unverified;
    case 'host':
      evidence = SourceEvidence.host;
    case 'sha256':
      evidence = SourceEvidence.sha256;
    default:
      throw AnchorCodecException('Anchor identity carries unknown sourceEvidence "$evidenceName"');
  }

  try {
    return PublicationRevision(
      publicationId: _requiredString(map, 'publicationId', limits.maxSelectorLength),
      editionId: _optionalString(map['editionId'], 'editionId', limits),
      sourceRevision: _optionalString(map['sourceRevision'], 'sourceRevision', limits),
      sourceEvidence: evidence,
    );
  } on ArgumentError catch (error) {
    throw AnchorCodecException('Anchor identity failed validation: ${error.message}');
  }
}

SectionOccurrence _decodeOccurrence(final Map<String, Object?> map, final AnchorLimits limits) {
  final sectionIndex = map['sectionIndex'];
  final readingOrderRevision = map['readingOrderRevision'];
  if (sectionIndex is! int) {
    throw const AnchorCodecException('Anchor occurrence.sectionIndex must be an integer');
  }
  if (readingOrderRevision != null && readingOrderRevision is! String) {
    throw const AnchorCodecException('Anchor readingOrderRevision must be a string or null');
  }

  try {
    return SectionOccurrence(
      sectionIndex: sectionIndex,
      resourcePath: _requiredString(map, 'resourcePath', limits.maxSelectorLength),
      readingOrderRevision: readingOrderRevision as String?,
    );
  } on ArgumentError catch (error) {
    throw AnchorCodecException('Anchor occurrence failed validation: ${error.message}');
  }
}

TextProfile _decodeProfile(final Map<String, Object?> map, final AnchorLimits limits) {
  final optionsJson = map['options'];
  final options = <String, String>{};
  if (optionsJson != null) {
    if (optionsJson is! Map) {
      throw const AnchorCodecException('Anchor profile.options must be an object');
    }
    for (final entry in optionsJson.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! String) {
        throw const AnchorCodecException('Anchor profile options must map strings to strings');
      }
      if (key.length > limits.maxSelectorLength || value.length > limits.maxSelectorLength) {
        throw const AnchorCodecException('Anchor profile option exceeds its size limit');
      }
      options[key] = value;
    }
  }

  try {
    final profile = TextProfile.of(
      algorithm: _requiredString(map, 'algorithm', limits.maxSelectorLength),
      options: options,
      planRevision: _requiredString(map, 'planRevision', limits.maxSelectorLength),
    );
    final carriedId = map['id'];
    if (carriedId is! String || carriedId != profile.id) {
      throw const AnchorCodecException(
        'Carried profile id does not match the digest of the carried parts',
      );
    }

    return profile;
  } on ArgumentError catch (error) {
    throw AnchorCodecException('Anchor profile failed validation: ${error.message}');
  }
}

String _requiredString(final Map<String, Object?> map, final String key, final int maxLength) {
  final value = map[key];
  if (value is! String) {
    throw AnchorCodecException('Anchor payload field $key must be a string');
  }
  if (value.length > maxLength) {
    throw AnchorCodecException(
      'Anchor payload field $key exceeds its limit ($maxLength code units)',
    );
  }

  return value;
}

String? _optionalString(final Object? value, final String key, final AnchorLimits limits) {
  if (value == null) return null;
  if (value is! String) {
    throw AnchorCodecException('Anchor payload field $key must be a string or null');
  }
  if (value.length > limits.maxSelectorLength) {
    throw AnchorCodecException(
      'Anchor payload field $key exceeds its limit '
      '(${limits.maxSelectorLength} code units)',
    );
  }

  return value;
}
