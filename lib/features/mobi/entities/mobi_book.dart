import 'package:e_livre/features/core/book/book.dart';
import 'package:e_livre/features/core/entities/book/files.dart';
import 'package:e_livre/features/core/entities/book_metadata.dart';
import 'package:e_livre/features/core/entities/file/binary_file.dart';
import 'package:e_livre/features/core/entities/navigation/navigation.dart';
import 'package:e_livre/features/mobi/header/mobi_header.dart';
import 'package:e_livre/features/mobi/utils/mobi_metadata_mapper.dart';

/// A parsed MOBI 6 / KF8 (AZW3) book.
class MobiBook extends Book {
  /// Creates a [MobiBook] from already parsed parts.
  MobiBook({
    required this.navigation,
    required this.files,
    required this.cover,
    required this.header,
    required super.format,
  });

  /// The navigation (table of contents) of the book.
  @override
  final Navigation navigation;

  /// The files extracted from the book.
  @override
  final Files files;

  /// The cover image, or an empty file when none was found.
  final BinaryFile cover;

  /// The MOBI header the book was parsed from.
  final MobiHeader header;

  /// The format-agnostic metadata of this book.
  @override
  BookMetadata get metadata => mobiBookMetadata(header, coverFile: cover);

  /// The book title.
  String get title => header.exth?.title ?? header.title;

  /// The book author names.
  List<String> get creators =>
      metadata.authors;

  /// The book language code.
  String get language => metadata.languages.isEmpty ? '' : metadata.languages.first;

  /// The book publisher.
  String? get publisher => metadata.publisher;

  /// The MOBI version (6 or 8).
  int get version => header.mobiVersion;
}
