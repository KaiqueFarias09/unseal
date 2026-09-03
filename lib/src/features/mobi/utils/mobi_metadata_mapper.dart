import 'package:e_livre/src/features/mobi/header/exth_header.dart';
import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/utils/langcodes.dart';
import 'package:e_livre/src/foundation/entities/book_cover.dart';
import 'package:e_livre/src/foundation/entities/book_format.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';
import 'package:e_livre/src/foundation/entities/file/binary_file.dart';
import 'package:e_livre/src/foundation/utils/image_size.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';

/// Maps a MOBI [header] (+ optional PDB name) into [BookMetadata].
BookMetadata mobiBookMetadata(
  final MobiHeader header, {
  final String? pdbName,
  final BinaryFile? coverFile,
  final BookFormat? formatOverride,
}) {
  final exth = header.exth;
  final codec = header.codec;

  // Title: EXTH 503 (authoritative) > MOBI header > PDB name.
  var title = exth?.title ?? header.title;
  if (title.isEmpty) {
    title = pdbName ?? '';
  }

  // Authors: EXTH 100; Amazon stores `Last, First` — flip when clear.
  final authors = <String>[];
  for (final raw in exth?.strings(ExthIds.author, codec) ?? const <String>[]) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final match = RegExp(r'^([^,]+?),\s+([^,]+)$').firstMatch(trimmed);
    authors.add(match != null ? '${match.group(2)} ${match.group(1)}' : trimmed);
  }

  final languages = <String>[];
  final exthLanguage = exth?.string(ExthIds.language, codec)?.trim();
  if (exthLanguage != null && exthLanguage.isNotEmpty) {
    languages.add(exthLanguage.toLowerCase());
  } else if (!header.ancient) {
    final resolved = resolveMobiLanguage(header.langCode);
    if (resolved.isNotEmpty) {
      languages.add(resolved);
    }
  }

  var publisher = exth?.string(ExthIds.publisher, codec)?.trim();
  if (publisher != null && (publisher.isEmpty || publisher.toLowerCase() == 'unknown')) {
    publisher = null;
  }

  final isbn = exth?.string(ExthIds.isbn, codec)?.trim();
  final hasIsbn = isbn != null && RegExp(r'^[\dXx\-]{10,17}$').hasMatch(isbn);
  final cleanIsbn = hasIsbn ? isbn.replaceAll(RegExp(r'[-\s]'), '').toUpperCase() : null;

  final subjects = <String>[];
  for (final raw in exth?.strings(ExthIds.subject, codec) ?? const <String>[]) {
    for (final part in raw.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty && !subjects.contains(trimmed)) {
        subjects.add(trimmed);
      }
    }
  }

  final identifiers = <String, String>{};
  final asin = exth?.string(ExthIds.asin, 'ascii')?.trim();
  if (asin != null && asin.isNotEmpty) {
    identifiers['asin'] = asin;
  }
  final source = exth?.string(ExthIds.source, codec)?.trim();
  if (source != null && source.isNotEmpty) {
    if (source.toLowerCase().startsWith('urn:isbn:')) {
      // Merged into isbn when valid.
    } else if (source.startsWith('calibre:')) {
      final uuid = source.substring('calibre:'.length);
      if (uuid.isNotEmpty) {
        identifiers['uuid'] = uuid;
      }
    }
  }
  if (!header.ancient && header.uniqueId > 0) {
    identifiers['mobi-id'] = '${header.uniqueId}';
  }

  return BookMetadata(
    format: formatOverride ?? (header.mobiVersion == 8 ? BookFormat.azw3 : BookFormat.mobi),
    title: title.isEmpty ? null : title,
    authors: authors,
    languages: languages,
    publisher: publisher,
    description: exth?.string(ExthIds.description, codec)?.trim(),
    isbn: cleanIsbn,
    subjects: subjects,
    publishedAt: _parseMobiDate(exth?.string(ExthIds.publishDate, codec)),
    rights: exth?.string(ExthIds.rights, codec)?.trim(),
    identifiers: identifiers,
    cover: _coverFrom(coverFile),
  );
}

BookCover? _coverFrom(final BinaryFile? coverFile) {
  if (coverFile == null || coverFile.isEmpty) {
    return null;
  }
  final type = sniffImageType(coverFile.content);
  if (type == null) {
    return null;
  }
  final size = imageSize(coverFile.content);
  return BookCover(bytes: coverFile.content, type: type, width: size?.width, height: size?.height);
}

DateTime? _parseMobiDate(final String? raw) {
  if (raw == null) {
    return null;
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final direct = DateTime.tryParse(trimmed);
  if (direct != null) {
    return direct;
  }
  final match = RegExp(r'^(\d{4})(?:[-/.](\d{1,2}))?(?:[-/.](\d{1,2}))?').firstMatch(trimmed);
  if (match == null) {
    return null;
  }
  final month = match.group(2) != null ? int.parse(match.group(2)!) : 1;
  final day = match.group(3) != null ? int.parse(match.group(3)!) : 1;
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return DateTime(int.parse(match.group(1)!));
  }
  return DateTime(int.parse(match.group(1)!), month, day);
}
