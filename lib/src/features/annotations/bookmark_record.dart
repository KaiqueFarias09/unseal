/// A quick bookmark: a named reading position — one section's
/// document text at a character offset. The position is carried
/// structurally (not as a serialized locator string) so hosts can
/// re-target it into their own position vocabulary.
final class BookmarkRecord {
  /// Creates a [BookmarkRecord].
  const BookmarkRecord({
    required this.id,
    required this.title,
    required this.sectionIndex,
    required this.charOffset,
    required this.createdAt,
    this.note,
  });

  /// Unique identifier.
  final String id;

  /// Display title (also a merge identity: bookmarks match by title
  /// or by position).
  final String title;

  /// Index of the content section inside the book's reading order.
  final int sectionIndex;

  /// Character offset within the section's document text.
  final int charOffset;

  /// Creation timestamp (merge ordering key).
  final DateTime createdAt;

  /// Optional note attached to the bookmark.
  final String? note;

  @override
  bool operator ==(final Object other) =>
      other is BookmarkRecord &&
      other.id == id &&
      other.title == title &&
      other.sectionIndex == sectionIndex &&
      other.charOffset == charOffset &&
      other.createdAt == createdAt &&
      other.note == note;

  @override
  int get hashCode => Object.hash(id, title, sectionIndex, charOffset, createdAt, note);
}
