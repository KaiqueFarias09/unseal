/// A named destination in an EPUB 3 landmarks navigation section.
///
/// [types] contains the link's `epub:type` tokens, such as `cover`,
/// `bodymatter`, or `toc`. EPUB allows additional vocabulary terms, so the
/// original tokens are preserved instead of reducing them to a closed enum.
final class EpubLandmark {
  /// Creates a landmark from the navigation link.
  EpubLandmark({required this.label, required this.href, required this.types});

  /// The visible link label.
  final String label;

  /// The link target, relative to the EPUB navigation document.
  final String href;

  /// Semantic `epub:type` tokens declared on the link.
  final List<String> types;
}
