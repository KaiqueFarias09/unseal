import 'revision_digest.dart';

/// The extraction profile a canonical text was produced under.
///
/// The profile is part of snapshot identity: text captured under one
/// algorithm, option set or extraction plan does not silently reuse
/// under another. Two PDF reading modes that derive their canonical
/// text from different extraction plans — whole-document statistics
/// versus a bounded sample — therefore carry different profile ids by
/// construction, never by convention.
final class TextProfile {
  /// Computes the profile from its parts: [id] is the
  /// [RevisionDigest.textProfileRevision] digest of [algorithm],
  /// [options] and [planRevision], so equal parts always agree on the
  /// id and any difference (an option, a plan revision) changes it.
  ///
  /// [planRevision] is itself a `sha256:`-prefixed digest of the
  /// extraction plan's decisions, minted by the feature that ran the
  /// plan. Options are string-valued and stable; the digest sorts
  /// their keys.
  factory TextProfile.of({
    required final String algorithm,
    required final Map<String, String> options,
    required final String planRevision,
  }) {
    final optionKeys = options.keys.toList()..sort();
    final canonicalOptions = Map<String, String>.unmodifiable({
      for (final key in optionKeys) key: options[key]!,
    });
    return TextProfile._(
      algorithm: algorithm,
      options: canonicalOptions,
      planRevision: planRevision,
      id: RevisionDigest.textProfileRevision(
        algorithm: algorithm,
        options: canonicalOptions,
        planRevision: planRevision,
      ),
    );
  }

  const TextProfile._({
    required this.algorithm,
    required this.options,
    required this.planRevision,
    required this.id,
  });

  /// The extraction algorithm (`pdf.reflow`, a future indexer's own…).
  final String algorithm;

  /// The immutable algorithm options that shaped the text, sorted by key.
  final Map<String, String> options;

  /// The `sha256:`-prefixed digest of the extraction plan's decisions.
  final String planRevision;

  /// The `sha256:`-prefixed profile identity: the digest of
  /// algorithm, sorted options and plan revision.
  final String id;

  /// Whether both profiles describe the same extraction.
  bool sameProfile(final TextProfile other) => id == other.id;

  @override
  bool operator ==(final Object other) =>
      other is TextProfile &&
      algorithm == other.algorithm &&
      planRevision == other.planRevision &&
      _sameOptions(other);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TextProfile($id, $algorithm, options: $options)';

  bool _sameOptions(final TextProfile other) {
    if (options.length != other.options.length) return false;
    for (final key in options.keys) {
      if (options[key] != other.options[key]) return false;
    }

    return true;
  }
}
