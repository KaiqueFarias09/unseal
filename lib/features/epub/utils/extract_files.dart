import 'dart:convert' as convert;
import 'dart:typed_data';

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
        content: Uint8List.fromList(entry.content as List<int>),
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
        content: convert.utf8.decode(entry.content as List<int>),
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
  final resolved = <ArchiveFile>[];
  for (final item in items) {
    ArchiveFile? match;
    final itemPath = resolveItemPath(rootFilePath, item.path);
    for (final file in files) {
      if (!file.isFile) continue;
      if (normalizeZipPath(file.name).toLowerCase() == itemPath.toLowerCase()) {
        match = file;
        break;
      }
    }
    if (match != null) {
      resolved.add(match);
    }
  }
  return resolved;
}
