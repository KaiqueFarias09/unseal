import 'dart:typed_data';

import '../../../../foundation/entities/entities.dart';
import '../../../../foundation/language/rtl_languages.dart';
import '../../epub_document.dart';
import '../../exceptions/exceptions.dart';
import '../../metadata/epub_metadata.dart';
import '../../parse_epub_book.dart';
import '../package/epub_3_package.dart';
import '../package/epub_package.dart';
import '../package/epub_rendition.dart';
import '../package/epub_viewport.dart';
import '../package/page_progression_direction.dart';
import 'epub_landmark.dart';

/// A parsed EPUB 2.0 / 3.0 book.
final class EpubBook extends Book implements EpubDocument {
  /// Creates an [EpubBook] from already parsed parts.
  EpubBook({
    required this.navigation,
    required this.files,
    required this.cover,
    required this.package,
    this.pageList,
    this.landmarks = const <EpubLandmark>[],
    this.spinePaths,
    this.spineIdrefs,
    this.contentViewports = const <String, EpubViewport>{},
    this.nonLinearSpinePaths = const <String>{},
    this.archiveEntries = const <ArchiveEntry>[],
  }) : super(format: BookFormat.epub);

  /// The navigation (table of contents) of the book.
  @override
  final Navigation navigation;

  /// EPUB 3 page labels and destinations, when the nav document declares a page list.
  @override
  final Navigation? pageList;

  /// EPUB 3 structural destinations, with their semantic `epub:type` values.
  @override
  final List<EpubLandmark> landmarks;

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

  /// Manifest identifiers parallel to [spinePaths]: the spine `idref`
  /// of each reading-order entry (computed at parse time for the same
  /// reason as [spinePaths]). Null when the spine could not be resolved.
  final List<String>? spineIdrefs;

  /// Declared page dimensions of the fixed-layout content documents,
  /// keyed by content path (the same key space as `files.html`).
  ///
  /// XHTML pages report their `<meta name="viewport">` declaration;
  /// standalone SVG pages report the root `<svg>` size. Only documents
  /// declaring a usable viewport appear; documents are scanned
  /// only when the spine references them.
  final Map<String, EpubViewport> contentViewports;

  /// Content paths whose spine `itemref` declares `linear="no"`.
  final Set<String> nonLinearSpinePaths;

  /// The HTML content files.
  @override
  List<TextFile> get content => files.html;

  /// The image files.
  @override
  List<BinaryFile> get images => files.images;

  /// The format-agnostic metadata of this book.
  @override
  BookMetadata get metadata => epubBookMetadata(package, cover);

  /// The EPUB spine in reading order.
  @override
  List<ReadingOrderItem> get readingOrder {
    return spinePaths == null
        ? super.readingOrder
        : <ReadingOrderItem>[for (final path in spinePaths!) ReadingOrderItem(name: path)];
  }

  /// The page-flow direction a reader should honor for this book.
  ///
  /// The spine's declared `page-progression-direction` wins; when the book
  /// declares no direction, `rtl` is inferred from the book's primary
  /// language ([isRtlLanguage]); books that declare neither stay
  /// [PageProgressionDirection.unspecified].
  PageProgressionDirection get effectivePageProgressionDirection {
    final declared = package.spine.pageProgressionDirection;
    if (declared != PageProgressionDirection.unspecified) return declared;

    return isRtlLanguage(package.metadata.language)
        ? PageProgressionDirection.rtl
        : PageProgressionDirection.unspecified;
  }

  /// Effective layout of the reading-order item at [index]: the spine
  /// item's `rendition:layout` override when declared, otherwise the
  /// publication-wide setting. EPUB 2 books and books without a
  /// resolvable spine stay [EpubLayout.reflowable].
  ///
  /// Throws [RangeError] when [index] is outside the reading order.
  EpubLayout layoutForSpineIndex(final int index) =>
      _renditionForSpineIndex(
        index,
        (final rendition, final idref) => rendition.layoutFor(idref),
      ) ??
      EpubLayout.reflowable;

  /// Effective orientation preference of the reading-order item at
  /// [index], defaulting to [EpubOrientation.auto] like [EpubLayout].
  ///
  /// Throws [RangeError] when [index] is outside the reading order.
  EpubOrientation orientationForSpineIndex(final int index) =>
      _renditionForSpineIndex(
        index,
        (final rendition, final idref) => rendition.orientationFor(idref),
      ) ??
      EpubOrientation.auto;

  /// Effective synthetic-spread preference of the reading-order item at
  /// [index], defaulting to [EpubSpread.auto].
  ///
  /// Throws [RangeError] when [index] is outside the reading order.
  EpubSpread spreadForSpineIndex(final int index) =>
      _renditionForSpineIndex(
        index,
        (final rendition, final idref) => rendition.spreadFor(idref),
      ) ??
      EpubSpread.auto;

  /// Placement in a synthetic spread declared by the reading-order item
  /// at [index], or `null` when the item declares none (or the book has
  /// no EPUB 3 rendition settings).
  ///
  /// Throws [RangeError] when [index] is outside the reading order.
  EpubPageSpread? pageSpreadForSpineIndex(final int index) =>
      _renditionForSpineIndex<EpubPageSpread?>(
        index,
        (final rendition, final idref) => rendition.pageSpreadFor(idref),
      );

  /// Declared page dimensions of the reading-order item at [index], or
  /// `null` when the document declares no usable viewport.
  ///
  /// Throws [RangeError] when [index] is outside the reading order.
  EpubViewport? viewportForSpineIndex(final int index) =>
      contentViewports[_spinePathForIndex(index)];

  /// Whether the reading-order item at [index] is a linear spine item.
  /// Non-linear items declare `linear="no"` and may be skipped during
  /// sequential reading; every other item is linear.
  ///
  /// Throws [RangeError] when [index] is outside the reading order.
  bool spineItemIsLinear(final int index) =>
      !nonLinearSpinePaths.contains(_spinePathForIndex(index));

  /// The content path of reading-order item [index].
  String _spinePathForIndex(final int index) {
    final order = readingOrder;
    RangeError.range(index, 0, order.length - 1, 'index');

    return order[index].name;
  }

  /// Resolves the EPUB 3 rendition settings of reading-order item
  /// [index] through its spine idref, or `null` when the item has no
  /// rendition resolution (EPUB 2, unresolvable spine, or idref unknown
  /// to the manifest).
  R? _renditionForSpineIndex<R>(
    final int index,
    final R Function(EpubRendition rendition, String idref) resolve,
  ) {
    final package = this.package;
    if (package is! Epub3Package) return null;

    final spinePaths = this.spinePaths;
    final idref = spinePaths == null ? null : spineIdrefs?[index];
    if (idref == null) return null;

    return resolve(package.renditionSettings, idref);
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
