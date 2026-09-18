/// A quick bookmark: a named reading position — one section's document text at a character offset.
/// The position is carried structurally (not as a serialized locator string) so hosts can re-target
/// it into their own position vocabulary.
final class BookmarkRecord {
  /// Creates a [BookmarkRecord].
  factory BookmarkRecord({
    required final String id,
    required final String title,
    required final int sectionIndex,
    required final int charOffset,
    required final DateTime createdAt,
    final String? note,
  }) {
    if (sectionIndex < 0) {
      throw ArgumentError.value(sectionIndex, 'sectionIndex', 'must not be negative');
    }
    if (charOffset < 0) throw ArgumentError.value(charOffset, 'charOffset', 'must not be negative');

    return BookmarkRecord._(
      id: id,
      title: title,
      sectionIndex: sectionIndex,
      charOffset: charOffset,
      createdAt: createdAt,
      note: note,
    );
  }

  const BookmarkRecord._({
    required this.id,
    required this.title,
    required this.sectionIndex,
    required this.charOffset,
    required this.createdAt,
    required this.note,
  });

  /// Unique identifier.
  final String id;

  /// Display title (also a merge identity: bookmarks match by title or by position).
  final String title;

  /// Index of the content section inside the book's reading order.
  final int sectionIndex;

  /// Character offset within the section's document text.
  final int charOffset;

  /// Creation timestamp (merge ordering key).
  final DateTime createdAt;

  /// Optional note attached to the bookmark.
  final String? note;

  /// Returns this bookmark with [title].
  BookmarkRecord withTitle(final String title) {
    return BookmarkRecord(
      id: id,
      title: title,
      sectionIndex: sectionIndex,
      charOffset: charOffset,
      createdAt: createdAt,
      note: note,
    );
  }

  /// Returns this bookmark with [note], including `null` to clear it.
  BookmarkRecord withNote(final String? note) {
    return BookmarkRecord(
      id: id,
      title: title,
      sectionIndex: sectionIndex,
      charOffset: charOffset,
      createdAt: createdAt,
      note: note,
    );
  }

  @override
  bool operator ==(final Object other) {
    return other is BookmarkRecord &&
        other.id == id &&
        other.title == title &&
        other.sectionIndex == sectionIndex &&
        other.charOffset == charOffset &&
        other.createdAt == createdAt &&
        other.note == note;
  }

  @override
  int get hashCode => Object.hash(id, title, sectionIndex, charOffset, createdAt, note);
}
