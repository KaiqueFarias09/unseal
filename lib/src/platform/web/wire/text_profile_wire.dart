import '../../../foundation/text/text_profile.dart';

/// Encodes a canonical extraction profile with the parts that bind its id.
Map<String, Object?> encodeTextProfileWire(final TextProfile profile) => <String, Object?>{
  'id': profile.id,
  'algorithm': profile.algorithm,
  'options': <String, String>{...profile.options},
  'planRevision': profile.planRevision,
};

/// Rebuilds an optional profile and rejects a contradictory carried id.
TextProfile? decodeTextProfileWire(final Object? value) {
  if (value == null) return null;
  final map = value as Map<String, Object?>;
  final profile = TextProfile.of(
    algorithm: map['algorithm'] as String,
    options: Map<String, String>.from(map['options'] as Map),
    planRevision: map['planRevision'] as String,
  );
  if (profile.id != map['id']) {
    throw ArgumentError('Wire canonical text profile does not match its parts');
  }
  return profile;
}
