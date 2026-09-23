/// EPUB accessibility metadata declared in the OPF package document.
///
/// Vocabulary values stay as strings so newer schema.org terms remain visible
/// without requiring a library update. Each [sufficientAccessModes] entry is
/// one independent combination sufficient to consume the publication.
final class EpubAccessibility {
  /// Creates grouped EPUB accessibility metadata.
  const EpubAccessibility({
    this.accessModes = const <String>[],
    this.sufficientAccessModes = const <List<String>>[],
    this.features = const <String>[],
    this.hazards = const <String>[],
    this.summaries = const <String>[],
  });

  /// Modes needed to perceive the unadapted content.
  final List<String> accessModes;

  /// Independent sets of modes sufficient to consume the publication.
  final List<List<String>> sufficientAccessModes;

  /// Accessibility features declared by the publisher.
  final List<String> features;

  /// Accessibility hazards declared by the publisher.
  final List<String> hazards;

  /// Human-readable descriptions of accessibility and its limitations.
  final List<String> summaries;
}
