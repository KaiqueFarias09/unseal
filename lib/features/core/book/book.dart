import 'package:e_livre/e_livre.dart' show EpubBook, MobiBook, Fb2Book;
import 'package:e_livre/features/core/entities/book/files.dart';
import 'package:e_livre/features/core/entities/book_format.dart';
import 'package:e_livre/features/core/entities/book_metadata.dart';
import 'package:e_livre/features/core/entities/navigation/navigation.dart';

/// A fully parsed book, independent of its source format.
///
/// Every format module exposes a concrete book type ([EpubBook],
/// [MobiBook], [Fb2Book]) implementing this contract:
///
/// * [metadata] — common book metadata (title, authors, cover, ...).
/// * [navigation] — the table of contents.
/// * [files] — extracted content files (html, css, images, fonts, ...).
///
/// The cover is available through `metadata.cover`.
abstract class Book {
  /// Creates a [Book] tagged with its [format].
  const Book({required this.format});

  /// The format this book was parsed from.
  final BookFormat format;

  /// The format-agnostic metadata of this book.
  BookMetadata get metadata;

  /// The navigation (table of contents) of this book.
  Navigation get navigation;

  /// The extracted files of this book.
  Files get files;
}
