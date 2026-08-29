import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/features/core/book/book.dart';
import 'package:e_livre/features/core/entities/book/files.dart';
import 'package:e_livre/features/core/entities/book_format.dart';
import 'package:e_livre/features/core/entities/book_metadata.dart';
import 'package:e_livre/features/core/entities/file/binary_file.dart';
import 'package:e_livre/features/core/entities/file/text_file.dart';
import 'package:e_livre/features/core/entities/navigation/navigation.dart';
import 'package:e_livre/features/epub/entities/package/epub_package.dart';
import 'package:e_livre/features/epub/exceptions/empty_bytes_exception.dart';
import 'package:e_livre/features/epub/exceptions/epub_exception.dart';
import 'package:e_livre/features/epub/utils/epub_metadata_mapper.dart';
import 'package:e_livre/features/epub/utils/parse_epub_book.dart';
import 'package:path/path.dart' as path;

/// A parsed EPUB 2.0 / 3.0 book.
class EpubBook extends Book {
  /// Creates an [EpubBook] from already parsed parts.
  EpubBook({
    required this.navigation,
    required this.files,
    required this.cover,
    required this.package,
  }) : super(format: BookFormat.epub);

  /// Reads an EPUB book from the file at [filePath].
  static Future<EpubBook> fromFilePath(final String filePath) {
    final file = _getFileIfValid(filePath);
    return fromFile(file);
  }

  /// Reads an EPUB book from [file].
  static Future<EpubBook> fromFile(final File file) {
    if (!file.existsSync()) throw EpubException('No such file or directory');
    return fromBytes(file.readAsBytesSync());
  }

  /// Reads an EPUB book from the provided [bytes].
  static Future<EpubBook> fromBytes(final List<int> bytes) {
    if (bytes.isEmpty) throw EmptyBytesException();
    return Future.value(parseEpubBook(Uint8List.fromList(bytes)));
  }

  /// The navigation (table of contents) of the book.
  @override
  final Navigation navigation;

  /// The files extracted from the book.
  @override
  final Files files;

  /// The cover image, or an empty file when none was found.
  final BinaryFile cover;

  /// The parsed OPF package.
  final EpubPackage package;

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
  List<TextFile> get content => files.html;

  /// The image files.
  List<BinaryFile> get images => files.images;

  static File _getFileIfValid(final String filePath) {
    if (filePath.isEmpty) throw EpubException('Path cannot be empty');

    final sanitizedPath = path.normalize(filePath);
    return File(sanitizedPath);
  }
}
