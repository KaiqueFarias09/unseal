import 'revision_digest.dart';

/// One occurrence of a content section inside a publication's reading
/// order.
///
/// The same parser resource path can appear more than once (a repeated
/// page or chapter); each position in the reading order is its own
/// occurrence, so equality compares all three fields and repeated
/// paths stay distinct.
final class SectionOccurrence {
  /// Creates an occurrence; [ArgumentError] reports contract
  /// violations.
  ///
  /// [sectionIndex] is the zero-based position in the reading order.
  /// [resourcePath] is the parser's exact path (`page_1.html` keeps its
  /// historical convention). [readingOrderRevision] is the
  /// `sha256:`-prefixed digest [RevisionDigest.readingOrderRevision]
  /// computes over the complete ordered path array; it stays null only
  /// while the reading order is unknown, which marks the occurrence
  /// in-memory only.
  SectionOccurrence({
    required this.sectionIndex,
    required this.resourcePath,
    required this.readingOrderRevision,
  }) {
    if (sectionIndex < 0) {
      throw ArgumentError.value(
        sectionIndex,
        'sectionIndex',
        'Must be zero-based and non-negative',
      );
    }
    if (resourcePath.isEmpty) {
      throw ArgumentError.value(resourcePath, 'resourcePath', 'Must be the parser\'s exact path');
    }
    if (readingOrderRevision != null && !isSha256Revision(readingOrderRevision!)) {
      throw ArgumentError.value(
        readingOrderRevision,
        'readingOrderRevision',
        'Must be null or the exact sha256:<64 lowercase hex> shape',
      );
    }
  }

  /// The zero-based position of this section in the reading order.
  final int sectionIndex;

  /// The parser's exact resource path, repetitions included.
  final String resourcePath;

  /// The digest of the complete ordered reading order this position
  /// was taken from; null when unknown (in-memory work without an
  /// exportable reading order).
  final String? readingOrderRevision;

  /// Whether both records describe the same occurrence, comparing
  /// every field including the explicit null.
  bool sameOccurrence(final SectionOccurrence other) {
    return sectionIndex == other.sectionIndex &&
        resourcePath == other.resourcePath &&
        readingOrderRevision == other.readingOrderRevision;
  }

  @override
  bool operator ==(final Object other) => other is SectionOccurrence && sameOccurrence(other);

  @override
  int get hashCode => Object.hash(sectionIndex, resourcePath, readingOrderRevision);

  @override
  String toString() =>
      'SectionOccurrence($sectionIndex, $resourcePath, '
      'order: ${readingOrderRevision == null ? 'unknown' : '${readingOrderRevision!.substring(0, 15)}…'})';
}
