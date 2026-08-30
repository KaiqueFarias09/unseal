import 'dart:convert' as convert;

import 'package:archive/archive.dart';
import 'package:e_livre/features/core/entities/book/files.dart';
import 'package:e_livre/features/core/entities/file/binary_file.dart';
import 'package:e_livre/features/core/entities/file/text_file.dart';
import 'package:e_livre/features/epub/entities/package/epub_package.dart';
import 'package:e_livre/features/epub/utils/archive_utils.dart';

/// Extracts various types of files from an EPUB archive.
///
/// Manifest items are resolved to archive entries by exact path
/// (relative to the OPF [rootFilePath], case-insensitive) and bucketed
/// into images, CSS, HTML, fonts and other files.
Files extractFiles(
  final List<ArchiveFile> files,
  final List<ManifestItem> items, [
  final String? rootFilePath,
]) {
  final imageItems = items.where((final item) => item.mediaType.contains('image/'));
  final cssItems = items.where((final item) => item.mediaType.contains('text/css'));
  final htmlItems = items
      .where((final item) => item.mediaType.contains('application/xhtml+xml'));
  final fontItems = items.where(
    (final item) =>
        item.mediaType.contains('font') ||
        item.mediaType.contains('opentype'),
  );
  final otherItems = items.where(
    (final item) =>
        !item.mediaType.contains('image/') &&
        !item.mediaType.contains('text/css') &&
        !item.mediaType.contains('application/xhtml+xml') &&
        !item.mediaType.contains('font') &&
        !item.mediaType.contains('opentype'),
  );

  return Files(
    images: _binaryFiles(files, imageItems, rootFilePath),
    css: _textFiles(files, cssItems, rootFilePath),
    html: _textFiles(files, htmlItems, rootFilePath),
    fonts: _binaryFiles(files, fontItems, rootFilePath),
    others: _binaryFiles(files, otherItems, rootFilePath),
  );
}

List<BinaryFile> _binaryFiles(
  final List<ArchiveFile> files,
  final Iterable<ManifestItem> items,
  final String? rootFilePath,
) {
  final List<BinaryFile> result = [];
  for (final entry in _resolveEntries(files, items, rootFilePath)) {
    final name = entry.name.split('/').last;
    result.add(
      BinaryFile(
        name: name,
        type: name.contains('.') ? name.split('.').last : '',
        path: entry.name,
        content: contentBytes(entry),
      ),
    );
  }
  return result;
}

List<TextFile> _textFiles(
  final List<ArchiveFile> files,
  final Iterable<ManifestItem> items,
  final String? rootFilePath,
) {
  final List<TextFile> result = [];
  for (final entry in _resolveEntries(files, items, rootFilePath)) {
    final name = entry.name.split('/').last;
    result.add(
      TextFile(
        name: name,
        type: name.contains('.') ? name.split('.').last : '',
        path: entry.name,
        content: convert.utf8.decode(contentBytes(entry)),
      ),
    );
  }
  return result;
}

Iterable<ArchiveFile> _resolveEntries(
  final List<ArchiveFile> files,
  final Iterable<ManifestItem> items,
  final String? rootFilePath,
) {
  // Index the archive once by normalized, case-insensitive path; the
  // first entry wins, mirroring a linear scan's match preference.
  final filesByPath = <String, ArchiveFile>{};
  for (final file in files) {
    if (!file.isFile) {
      continue;
    }
    filesByPath.putIfAbsent(
      normalizeZipPath(file.name).toLowerCase(),
      () => file,
    );
  }

  final resolved = <ArchiveFile>[];
  for (final item in items) {
    final match = filesByPath[resolveItemPath(rootFilePath, item.path).toLowerCase()];
    if (match != null) {
      resolved.add(match);
    }
  }
  return resolved;
}
