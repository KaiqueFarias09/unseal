import '../../../foundation/entities/entities.dart';

/// A parsed comic book (CBZ / CBR).
///
/// Pages are exposed as image files in natural reading order;
/// metadata comes from the embedded `ComicInfo.xml` when present.
class ComicBook extends Book {
  /// Creates a [ComicBook] from already parsed parts.
  ComicBook({
    required this.cover,
    required this.metadata,
    required this.pages,
    required super.format,
  }) : files = Files(
         images: pages,
         css: const [],
         html: const [],
         fonts: const [],
         others: const [],
       ),
       navigation = Navigation(title: metadata.title ?? '', navPoints: const []);

  /// The cover image, or an empty file when none was found.
  final BinaryFile cover;

  /// The format-agnostic metadata of this book.
  @override
  final BookMetadata metadata;

  /// The comic pages, in natural reading order.
  final List<BinaryFile> pages;

  /// The extracted files of this book.
  @override
  final Files files;

  /// Comics carry no table of contents.
  @override
  final Navigation navigation;

  /// Number of pages.
  int get pageCount => pages.length;

  /// The comic pages in reading order.
  @override
  List<ReadingOrderItem> get readingOrder => <ReadingOrderItem>[
    for (final page in pages) ReadingOrderItem(name: page.path, isHtml: false),
  ];
}
