import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../foundation/archive/archive_access.dart';
import '../../../foundation/entities/book/files.dart';
import '../../../foundation/entities/file/binary_file.dart';
import '../../../foundation/entities/file/text_file.dart';
import '../codec/epub_xml.dart';
import '../encryption/epub_encryption.dart';
import '../entities/entities.dart';

/// Extracts various types of files from an EPUB archive.
///
/// Manifest items are resolved to archive entries by exact path
/// (relative to the OPF [rootFilePath], case-insensitive) and bucketed
/// into images, CSS, HTML, fonts and other files.
Files extractFiles(
  final List<ArchiveFile> files,
  final List<ManifestItem> items, [
  final String? rootFilePath,
  final EpubEncryption? encryption,
]) {
  final imageItems = items.where(_isImageItem);
  final cssItems = items.where(_isCssItem);
  final htmlItems = items.where(_isHtmlItem);
  final fontItems = items.where(_isFontItem);
  final otherItems = items.where((final item) {
    return !_isImageItem(item) && !_isCssItem(item) && !_isHtmlItem(item) && !_isFontItem(item);
  });

  return Files(
    images: _binaryFiles(files, imageItems, rootFilePath),
    css: _textFiles(files, cssItems, rootFilePath),
    html: _textFiles(files, htmlItems, rootFilePath),
    fonts: _binaryFiles(files, fontItems, rootFilePath, contentDecoder: encryption?.decodeFont),
    others: _binaryFiles(files, otherItems, rootFilePath),
  );
}

List<BinaryFile> _binaryFiles(
  final List<ArchiveFile> files,
  final Iterable<ManifestItem> items,
  final String? rootFilePath, {
  final Uint8List Function(ArchiveFile entry)? contentDecoder,
}) {
  final List<BinaryFile> result = [];
  for (final entry in _resolveEntries(files, items, rootFilePath)) {
    final name = entry.name.split('/').last;
    result.add(
      BinaryFile(
        name: name,
        type: name.contains('.') ? name.split('.').last : '',
        path: entry.name,
        content: contentDecoder == null ? contentBytes(entry) : contentDecoder(entry),
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
        content: decodeEpubText(contentBytes(entry)),
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
    if (!file.isFile) continue;

    filesByPath.putIfAbsent(normalizeZipPath(file.name).toLowerCase(), () => file);
  }

  final resolved = <ArchiveFile>[];
  for (final item in items) {
    final match = filesByPath[resolveItemPath(rootFilePath, item.path).toLowerCase()];
    if (match != null) resolved.add(match);
  }

  return resolved;
}

bool _isImageItem(final ManifestItem item) => _mediaType(item.mediaType).startsWith('image/');

bool _isCssItem(final ManifestItem item) => _mediaType(item.mediaType) == 'text/css';

bool _isHtmlItem(final ManifestItem item) {
  final mediaType = _mediaType(item.mediaType);
  if (mediaType == 'application/xhtml+xml' ||
      mediaType == 'application/xhtml' ||
      mediaType == 'text/xhtml' ||
      mediaType == 'text/html' ||
      mediaType == 'application/html') {
    return true;
  }

  final path = item.path.split('#').first.split('?').first.toLowerCase();

  return (mediaType == 'application/xml' || mediaType == 'text/xml') &&
      (path.endsWith('.html') || path.endsWith('.htm') || path.endsWith('.xhtml'));
}

bool _isFontItem(final ManifestItem item) {
  final mediaType = _mediaType(item.mediaType);
  if (mediaType.contains('font') ||
      mediaType.contains('opentype') ||
      mediaType.contains('truetype') ||
      mediaType.contains('woff')) {
    return true;
  }

  final path = item.path.split('#').first.split('?').first.toLowerCase();

  return path.endsWith('.ttf') ||
      path.endsWith('.otf') ||
      path.endsWith('.woff') ||
      path.endsWith('.woff2') ||
      path.endsWith('.eot');
}

String _mediaType(final String value) => value.split(';').first.trim().toLowerCase();
