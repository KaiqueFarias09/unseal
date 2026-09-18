import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

/// Finds an archive entry by [entryPath] with exact, normalized and case-insensitive matching.
///
/// Manifest hrefs are relative to their manifest file, so callers should resolve them with
/// [resolveItemPath] first.
ArchiveFile? findArchiveFile(final Archive archive, final String entryPath) {
  final normalized = normalizeZipPath(entryPath);
  if (normalized.isEmpty) return null;

  for (final file in archive.files) {
    if (!file.isFile) continue;

    final normalizedFileName = normalizeZipPath(file.name).toLowerCase();
    if (file.name != normalized && normalizedFileName != normalized.toLowerCase()) continue;

    return file;
  }

  return null;
}

/// Resolves a manifest [href] against its [rootFilePath], handling fragments and `..` segments.
String resolveItemPath(final String? rootFilePath, final String href) {
  final hrefWithoutFragment = href.split('#').first;
  final directory = path.posix.dirname(rootFilePath ?? '');

  return normalizeZipPath(
    directory == '.' || directory.isEmpty ? hrefWithoutFragment : '$directory/$hrefWithoutFragment',
  );
}

/// Normalizes a zip entry path: forward slashes, resolved `.`/`..` segments, no leading slash.
String normalizeZipPath(final String zipPath) {
  final segments = <String>[];
  for (final segment in zipPath.split('/')) {
    if (segment.isEmpty || segment == '.') continue;

    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }

    segments.add(segment);
  }

  return segments.join('/');
}

/// Returns archive entry content as a [Uint8List] without copying when the archive already decoded
/// it into one.
Uint8List contentBytes(final ArchiveFile entry) {
  final content = entry.content;
  if (content is Uint8List) return Uint8List.sublistView(content);

  return Uint8List.fromList(content as List<int>);
}
