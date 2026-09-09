import 'package:e_livre/src/features/epub/entities/entities.dart';

import 'package:e_livre/src/foundation/entities/entities.dart';

import 'package:e_livre/src/foundation/utils/image_size.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';
import 'package:e_livre/src/foundation/utils/metadata_utils.dart';

/// Maps an EPUB [package] into the common [BookMetadata].
///
/// When a full parse is available, pass the extracted [coverFile] so
/// the metadata carries the cover image bytes.
BookMetadata epubBookMetadata(final EpubPackage package, [final BinaryFile? coverFile]) {
  final metadata = package.metadata;
  final identifiers = <String, String>{};
  for (final identifier in metadata.identifiers) {
    final key = identifier == metadata.uniqueIdentifierValue
        ? 'unique-identifier'
        : 'identifier-${identifiers.length}';
    identifiers[key] = identifier;
  }

  return BookMetadata(
    format: BookFormat.epub,
    title: metadata.title.isEmpty ? null : metadata.title,
    authors: [if (metadata.creator?.isNotEmpty == true) metadata.creator!],
    languages: [if (metadata.language.isNotEmpty) metadata.language],
    publisher: metadata.publisher,
    description: metadata.description,
    isbn: _findIsbn(metadata.identifiers),
    subjects: [if (metadata.subject?.isNotEmpty == true) metadata.subject!],
    publishedAt: parseEpubDate(metadata.date),
    rights: metadata.rights?.firstOrNull,
    series: _seriesOf(package),
    seriesIndex: parseSeriesIndex(metadata.seriesIndex),
    titleSort: metadata.titleSort,
    authorSort: metadata.authorSort,
    bookProducer: metadata.bookProducer,
    identifiers: identifiers,
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

/// Parses an EPUB `dc:date` string, tolerating loose forms.
DateTime? parseEpubDate(final String raw) {
  if (raw.isEmpty) return null;

  final trimmed = raw.trim();
  final direct = DateTime.tryParse(trimmed);
  if (direct != null) return direct;

  final match = RegExp(r'^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?').firstMatch(trimmed);
  if (match == null) return null;

  return DateTime(
    int.parse(match.group(1)!),
    match.group(2) != null ? int.parse(match.group(2)!) : 1,
    match.group(3) != null ? int.parse(match.group(3)!) : 1,
  );
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

String? _seriesOf(final EpubPackage package) {
  final metadata = package.metadata;
  if (metadata.series != null && metadata.series!.isNotEmpty) return metadata.series;
  if (metadata is Epub3Metadata && metadata.belongsToCollection.isNotEmpty) {
    return metadata.belongsToCollection;
  }

  return null;
}
