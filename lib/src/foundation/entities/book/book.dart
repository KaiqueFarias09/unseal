import '../book_format.dart';
import '../book_metadata.dart';
import '../book_statistics.dart';
import '../navigation/navigation.dart';
import 'archive_entry.dart';
import 'files.dart';
import 'reading_order_item.dart';

/// A fully parsed book, independent of its source format.
///
/// Every format module exposes a concrete book type implementing this contract, such as EPUB, MOBI,
/// FB2, and comic books:
///
/// * [metadata] — common book metadata (title, authors, cover, ...).
/// * [navigation] — the table of contents.
/// * [files] — extracted content files (html, css, images, fonts, ...).
/// * [archiveEntries] — the physical entries of the container archive.
/// * [statistics] — word count and reading time estimates.
/// * [readingOrder] — the content files in reading order.
///
/// The cover is available through `metadata.cover`.
abstract class Book {
  /// Creates a [Book] tagged with its [format].
  Book({required this.format});

  /// The format this book was parsed from.
  final BookFormat format;

  /// Reading statistics over the HTML content, computed once on first access.
  late final BookStatistics statistics = BookStatistics.fromTexts(
    files.html.map((final file) => file.plainText),
  );

  /// The extracted files of this book.
  Files get files;

  /// The format-agnostic metadata of this book.
  BookMetadata get metadata;

  /// The navigation (table of contents) of this book.
  Navigation get navigation;

  /// The physical entries of the book's container archive (e.g. the EPUB zip),
  /// manifest-independent: infrastructure files such as `META-INF/container.xml` and stray entries
  /// are included, nothing is parsed. Empty for formats without an archive container (MOBI, plain
  /// FB2).
  List<ArchiveEntry> get archiveEntries => const <ArchiveEntry>[];

  /// The content files in reading order.
  ///
  /// The default is the extraction order of `files.html`; formats with an explicit order (the EPUB
  /// spine) override it, and comics list their pages with `isHtml: false`.
  List<ReadingOrderItem> get readingOrder {
    return <ReadingOrderItem>[for (final file in files.html) ReadingOrderItem(name: file.path)];
  }
}
