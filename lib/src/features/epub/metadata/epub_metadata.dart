import '../../../foundation/entities/entities.dart';
import '../../../foundation/images/image_dimensions.dart';
import '../../../foundation/images/image_type_sniffer.dart';
import '../../../foundation/metadata/series_index.dart';
import '../entities/entities.dart';

/// Maps an EPUB [package] into the common [BookMetadata].
///
/// When a full parse is available, pass the extracted [coverFile] so
/// the metadata carries the cover image bytes.
BookMetadata epubBookMetadata(final EpubPackage package, [final BinaryFile? coverFile]) {
  final metadata = package.metadata;

  return BookMetadata(
    format: BookFormat.epub,
    title: metadata.title.isEmpty ? null : metadata.title,
    authors: [if (metadata.creator?.isNotEmpty == true) metadata.creator!],
    languages: [if (metadata.language.isNotEmpty) metadata.language],
    publisher: metadata.publisher,
    description: metadata.description,
    isbn: _findIsbn(metadata.identifiers),
    subjects: [if (metadata.subject?.isNotEmpty == true) metadata.subject!],
    publishedAt: _parseEpubDate(metadata.date),
    rights: metadata.rights?.firstOrNull,
    series: _seriesOf(package),
    seriesIndex: parseSeriesIndex(metadata.seriesIndex),
    titleSort: metadata.titleSort,
    authorSort: metadata.authorSort,
    bookProducer: metadata.bookProducer,
    identifiers: _identifiersOf(metadata),
    cover: _coverFrom(coverFile),
  );
}

BookCover? _coverFrom(final BinaryFile? coverFile) {
  if (coverFile == null || coverFile.isEmpty) return null;

  final type = sniffImageType(coverFile.content);
  if (type == null) return null;

  final size = imageSize(coverFile.content);

  return BookCover(bytes: coverFile.content, type: type, width: size?.width, height: size?.height);
}

DateTime? _parseEpubDate(final String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  final partial = RegExp(r'^(\d{4})(?:-(\d{2}))?$').firstMatch(trimmed);
  if (partial != null) {
    final year = int.parse(partial.group(1)!);
    final month = partial.group(2) == null ? 1 : int.parse(partial.group(2)!);
    if (month < 1 || month > 12) return null;

    return DateTime(year, month);
  }

  final datePrefix = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(trimmed);
  if (datePrefix != null && !_isValidDate(datePrefix)) return null;

  return DateTime.tryParse(trimmed);
}

String? _findIsbn(final List<String> identifiers) {
  for (final identifier in identifiers) {
    final compact = identifier.replaceAll(RegExp(r'[-\s]'), '').toUpperCase();
    final isIsbn10 = compact.length == 10 && RegExp(r'^\d{9}[\dX]$').hasMatch(compact);
    final isIsbn13 = compact.length == 13 && RegExp(r'^97[89]\d{10}$').hasMatch(compact);
    if (isIsbn10 || isIsbn13) return compact;
  }

  return null;
}

Map<String, String> _identifiersOf(final Metadata metadata) {
  final identifiers = <String, String>{};
  for (final identifier in metadata.identifiers) {
    final key = identifier == metadata.uniqueIdentifierValue
        ? 'unique-identifier'
        : 'identifier-${identifiers.length}';
    identifiers[key] = identifier;
  }

  return identifiers;
}

bool _isValidDate(final RegExpMatch match) {
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime.utc(year, month, day);

  return date.year == year && date.month == month && date.day == day;
}

String? _seriesOf(final EpubPackage package) {
  final metadata = package.metadata;
  if (metadata.series != null && metadata.series!.isNotEmpty) return metadata.series;
  if (metadata is Epub3Metadata && metadata.belongsToCollection.isNotEmpty) {
    return metadata.belongsToCollection;
  }

  return null;
}
