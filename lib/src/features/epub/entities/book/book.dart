import 'dart:typed_data';

import 'package:e_livre/src/features/epub/entities/package/epub_package.dart';
import 'package:e_livre/src/features/epub/entities/package/page_progression_direction.dart';
import 'package:e_livre/src/features/epub/epub_document.dart';
import 'package:e_livre/src/features/epub/exceptions/exceptions.dart';
import 'package:e_livre/src/features/epub/metadata/epub_metadata.dart';
import 'package:e_livre/src/features/epub/parse_epub_book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/rtl_languages.dart';

/// A parsed EPUB 2.0 / 3.0 book.
class EpubBook extends Book implements EpubDocument {
  /// Creates an [EpubBook] from already parsed parts.
  EpubBook({
    required this.navigation,
    required this.files,
    required this.cover,
    required this.package,
    this.spinePaths,
    this.archiveEntries = const <ArchiveEntry>[],
  }) : super(format: BookFormat.epub);

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

  /// The physical zip entries of the container, manifest-independent.
  @override
  final List<ArchiveEntry> archiveEntries;

  /// Archive paths of the spine items in reading order (computed at
  /// parse time since it needs the OPF location). Falls back to the
  /// extraction order when the spine cannot be resolved.
  @override
  final List<String>? spinePaths;

  /// The HTML content files.
  @override
  List<TextFile> get content => files.html;

  /// The book creator (main author).
  String? get creator => package.metadata.creator;

  /// The image files.
  @override
  List<BinaryFile> get images => files.images;

  /// The book language.
  String get language => package.metadata.language;

  /// The format-agnostic metadata of this book.
  @override
  BookMetadata get metadata => epubBookMetadata(package, cover);

  /// The book publisher.
  String? get publisher => package.metadata.publisher;

  /// The EPUB spine in reading order.
  @override
  List<ReadingOrderItem> get readingOrder => spinePaths == null
      ? super.readingOrder
      : <ReadingOrderItem>[for (final path in spinePaths!) ReadingOrderItem(name: path)];

  /// The book title.
  String get title => package.metadata.title;

  /// The unique identifier value of the package.
  String get uid => package.metadata.uniqueIdentifierValue;

  /// The EPUB version (`2.0` or `3.0`).
  String get version => package.version;

  /// The page-flow direction a reader should honor for this book.
  ///
  /// Precedence mirrors Calibre's
  /// `set_page_progression_direction_if_needed`: the spine's declared
  /// `page-progression-direction` wins; when the book declares no
  /// direction, `rtl` is inferred from the book's primary language
  /// ([isRtlLanguage]); books that declare neither stay
  /// [PageProgressionDirection.unspecified].
  PageProgressionDirection get effectivePageProgressionDirection {
    final declared = package.spine.pageProgressionDirection;
    if (declared != PageProgressionDirection.unspecified) return declared;

    return isRtlLanguage(language)
        ? PageProgressionDirection.rtl
        : PageProgressionDirection.unspecified;
  }

  /// Reads an EPUB book from the provided [bytes].
  static Future<EpubBook> fromBytes(final List<int> bytes) {
    if (bytes.isEmpty) throw EmptyBytesException();
    // Skip the defensive copy when the caller already holds typed
    // data; parsing never mutates its input.
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    return Future.value(parseEpubBook(data));
  }
}
