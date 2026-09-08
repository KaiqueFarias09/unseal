import 'package:e_livre/src/foundation/entities/book/archive_entry.dart';
import 'package:e_livre/src/foundation/entities/book/book.dart';
import 'package:e_livre/src/foundation/entities/book/files.dart';
import 'package:e_livre/src/foundation/entities/book/reading_order_item.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';
import 'package:e_livre/src/foundation/entities/file/binary_file.dart';
import 'package:e_livre/src/foundation/entities/navigation/navigation.dart';

/// A document-backed book produced by text and office-format adapters.
///
/// The common model deliberately keeps the source format visible while
/// exposing the same reading primitives as EPUB: HTML content, resources,
/// navigation, metadata and an optional archive inventory. Format-specific
/// parsers own the conversion into this model; consumers do not need a
/// separate rendering contract for every container.
class DocumentBook extends Book {
  /// Creates a [DocumentBook] from parsed document parts.
  DocumentBook({
    required super.format,
    required this.files,
    required this.metadata,
    required this.navigation,
    this.cover,
    this.archiveEntries = const <ArchiveEntry>[],
    this.order,
  });

  /// Extracted document files and resources.
  @override
  final Files files;

  /// Format-agnostic metadata.
  @override
  final BookMetadata metadata;

  /// Headings and other document navigation points.
  @override
  final Navigation navigation;

  /// The extracted cover, when the source carries one.
  final BinaryFile? cover;

  /// Physical source-container inventory.
  @override
  final List<ArchiveEntry> archiveEntries;

  /// Explicit content order, when the source manifest declares one.
  final List<String>? order;

  /// Content files in source-defined order, falling back to extraction order.
  @override
  List<ReadingOrderItem> get readingOrder => order == null
      ? super.readingOrder
      : <ReadingOrderItem>[for (final path in order!) ReadingOrderItem(name: path)];
}
