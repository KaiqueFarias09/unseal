import 'package:e_livre/features/core/entities/book/files.dart';
import 'package:e_livre/features/core/entities/book/reading_order_item.dart';
import 'package:e_livre/features/core/entities/book_format.dart';
import 'package:e_livre/features/core/entities/book_metadata.dart';
import 'package:e_livre/features/core/entities/book_statistics.dart';
import 'package:e_livre/features/core/entities/navigation/navigation.dart';

/// A fully parsed book, independent of its source format.
///
/// Every format module exposes a concrete book type ([EpubBook],
/// [MobiBook], [Fb2Book], [ComicBook]) implementing this contract:
///
/// * [metadata] — common book metadata (title, authors, cover, ...).
/// * [navigation] — the table of contents.
/// * [files] — extracted content files (html, css, images, fonts, ...).
/// * [statistics] — word count and reading time estimates.
/// * [readingOrder] — the content files in reading order.
///
/// The cover is available through `metadata.cover`.
abstract class Book {
  /// Creates a [Book] tagged with its [format].
  Book({required this.format});

  /// The format this book was parsed from.
  final BookFormat format;

  /// The format-agnostic metadata of this book.
  BookMetadata get metadata;

  /// The navigation (table of contents) of this book.
  Navigation get navigation;

  /// The extracted files of this book.
  Files get files;

  /// Reading statistics over the HTML content, computed once on
  /// first access.
  late final BookStatistics statistics = BookStatistics.fromTexts(
    files.html.map((final file) => file.plainText),
  );

  /// The content files in reading order.
  ///
  /// The default is the extraction order of `files.html`; formats
  /// with an explicit order (the EPUB spine) override it, and comics
  /// list their pages with `isHtml: false`.
  List<ReadingOrderItem> get readingOrder => <ReadingOrderItem>[
        for (final file in files.html) ReadingOrderItem(name: file.path),
      ];
}
