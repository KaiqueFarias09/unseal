import 'dart:typed_data';

import 'package:e_livre/src/features/epub/entities/package/epub_package.dart';
import 'package:e_livre/src/features/epub/epub_document.dart';
import 'package:e_livre/src/features/epub/exceptions/empty_bytes_exception.dart';
import 'package:e_livre/src/features/epub/utils/epub_metadata_mapper.dart';
import 'package:e_livre/src/features/epub/utils/parse_epub_book.dart';
import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/book/files.dart';
import 'package:e_livre/src/foundation/entities/book/reading_order_item.dart';
import 'package:e_livre/src/foundation/entities/book_format.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';
import 'package:e_livre/src/foundation/entities/file/binary_file.dart';
import 'package:e_livre/src/foundation/entities/file/text_file.dart';
import 'package:e_livre/src/foundation/entities/navigation/navigation.dart';

/// A parsed EPUB 2.0 / 3.0 book.
class EpubBook extends Book implements EpubDocument {
  /// Creates an [EpubBook] from already parsed parts.
  EpubBook({
    required this.navigation,
    required this.files,
    required this.cover,
    required this.package,
    this.spinePaths,
  }) : super(format: BookFormat.epub);

  /// Reads an EPUB book from the provided [bytes].
  static Future<EpubBook> fromBytes(final List<int> bytes) {
    if (bytes.isEmpty) throw EmptyBytesException();
    // Skip the defensive copy when the caller already holds typed
    // data; parsing never mutates its input.
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return Future.value(parseEpubBook(data));
  }

  /// The navigation (table of contents) of the book.
  @override
  final Navigation navigation;

  /// The files extracted from the book.
  @override
  final Files files;

  /// The cover image, or an empty file when none was found.
  @override
  final BinaryFile cover;

  /// The parsed OPF package.
  @override
  final EpubPackage package;

  /// Archive paths of the spine items in reading order (computed at
  /// parse time since it needs the OPF location). Falls back to the
  /// extraction order when the spine cannot be resolved.
  @override
  final List<String>? spinePaths;

  /// The EPUB spine in reading order.
  @override
  List<ReadingOrderItem> get readingOrder => spinePaths == null
      ? super.readingOrder
      : <ReadingOrderItem>[for (final path in spinePaths!) ReadingOrderItem(name: path)];

  /// The format-agnostic metadata of this book.
  @override
  BookMetadata get metadata => epubBookMetadata(package, cover);

  /// The book title.
  String get title => package.metadata.title;

  /// The book creator (main author).
  String? get creator => package.metadata.creator;

  /// The book language.
  String get language => package.metadata.language;

  /// The book publisher.
  String? get publisher => package.metadata.publisher;

  /// The unique identifier value of the package.
  String get uid => package.metadata.uniqueIdentifierValue;

  /// The EPUB version (`2.0` or `3.0`).
  String get version => package.version;

  /// The HTML content files.
  @override
  List<TextFile> get content => files.html;

  /// The image files.
  @override
  List<BinaryFile> get images => files.images;
}
