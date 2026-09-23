/// Reading direction explicitly declared by ComicInfo.xml.
///
/// `Manga=YesAndRightToLeft` is the only ComicInfo value that declares a
/// direction. Other values leave the choice to the reading application.
enum ComicReadingDirection {
  /// No direction was declared; the reader chooses its default.
  unspecified,

  /// Pages are read from right to left.
  rightToLeft,
}

/// A page role declared by ComicInfo.xml.
enum ComicPageType {
  /// Outer front cover.
  frontCover,

  /// Cover inside the publication.
  innerCover,

  /// Recap of earlier issues.
  roundup,

  /// Main story content.
  story,

  /// Advertising page.
  advertisement,

  /// Editorial page.
  editorial,

  /// Reader letters.
  letters,

  /// Preview of another issue.
  preview,

  /// Outer back cover.
  backCover,

  /// Other known page role.
  other,

  /// Page marked for omission by a reading application.
  delete,

  /// A role token outside the recognized ComicInfo vocabulary.
  unknown;

  /// Resolves a schema value without losing unknown extensions.
  static ComicPageType fromComicInfo(final String value) => switch (value.toLowerCase()) {
    'frontcover' => frontCover,
    'innercover' => innerCover,
    'roundup' => roundup,
    'story' => story,
    'advertisement' => advertisement,
    'editorial' => editorial,
    'letters' => letters,
    'preview' => preview,
    'backcover' => backCover,
    'other' => other,
    'delete' => delete,
    _ => unknown,
  };
}

/// ComicInfo data for one image in `ComicBook.pages`.
///
/// [imageIndex] is zero-based and addresses the naturally ordered page list.
/// Declared dimensions and size come from the XML and are not verified against
/// image bytes. A `delete` role is exposed to the reader rather than silently
/// removing a page from the archive.
final class ComicPageInfo {
  /// Creates page data from an optional ComicInfo page declaration.
  const ComicPageInfo({
    required this.imageIndex,
    this.type = ComicPageType.story,
    this.rawType = 'Story',
    this.doublePage = false,
    this.bookmark,
    this.imageSize,
    this.imageWidth,
    this.imageHeight,
  });

  /// Index in the ordered `ComicBook.pages` list.
  final int imageIndex;

  /// Recognized page role, or [ComicPageType.unknown].
  final ComicPageType type;

  /// Original role token, including unknown extensions.
  final String rawType;

  /// Whether ComicInfo marks this image as a double-page spread.
  final bool doublePage;

  /// Optional user-facing bookmark label.
  final String? bookmark;

  /// Publisher-declared byte size, if positive.
  final int? imageSize;

  /// Publisher-declared width in pixels, if positive.
  final int? imageWidth;

  /// Publisher-declared height in pixels, if positive.
  final int? imageHeight;

  /// Returns the same declaration at a new index, for flattened CBC books.
  ComicPageInfo atIndex(final int index) => ComicPageInfo(
    imageIndex: index,
    type: type,
    rawType: rawType,
    doublePage: doublePage,
    bookmark: bookmark,
    imageSize: imageSize,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
}
