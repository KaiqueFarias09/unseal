import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/src/features/epub/entities/entities.dart';
import 'package:e_livre/src/foundation/entities/file/binary_file.dart';
import '../../../foundation/archive/archive_access.dart';

/// Resolves the manifest item that holds the cover image.
///
/// Precedence follows the EPUB specs (and mirrors Calibre):
///
/// 1. EPUB 3 `properties="cover-image"` manifest item.
/// 2. EPUB 2 `<meta name="cover" content="id"/>` referenced item.
/// 3. `<guide><reference type="cover" href="..."/></guide>`.
/// 4. Heuristic: manifest item whose id contains `cover` and whose
///    media type is an image.
ManifestItem? resolveCoverItem(final EpubPackage package) {
  final items = package.manifest.items;
  final propertyCover = items.firstWhereOrNull(
    (final item) => item.properties.contains('cover-image') && item.mediaType.contains('image/'),
  );
  if (propertyCover != null) return propertyCover;

  final coverId = package.metadata.coverId;
  if (coverId != null && coverId.isNotEmpty) {
    final metaCover = items.firstWhereOrNull((final item) => item.id == coverId);
    if (metaCover != null) return metaCover;
  }
  final guideReference = package.guide?.references.firstWhereOrNull(
    (final reference) => reference.type.toLowerCase() == 'cover',
  );
  if (guideReference != null) {
    final href = normalizeZipPath(guideReference.href.split('#').first);
    final guideCover = items.firstWhereOrNull((final item) => normalizeZipPath(item.path) == href);
    if (guideCover != null) return guideCover;
  }

  return items.firstWhereOrNull(
    (final item) => item.id.toLowerCase().contains('cover') && item.mediaType.contains('image/'),
  );
}

/// Retrieves the cover of the book from the package and the archive.
///
/// The cover item is resolved with [resolveCoverItem] and its entry is
/// looked up in the [archive] by exact path. When [images] from a full
/// extraction are available they are searched first, so the returned
/// file matches the extracted image list. Falls back to an empty
/// [BinaryFile] when no cover can be located.
BinaryFile getBookCover(
  final EpubPackage package,
  final Archive archive, [
  final List<BinaryFile> images = const [],
  final String? rootFilePath,
]) {
  final coverItem = resolveCoverItem(package);
  if (coverItem == null) return BinaryFile.empty();

  final resolvedPath = resolveItemPath(rootFilePath, coverItem.path);
  final fromImages = images.firstWhereOrNull(
    (final image) => normalizeZipPath(image.path).toLowerCase() == resolvedPath.toLowerCase(),
  );
  if (fromImages != null) return fromImages;

  final entry = findArchiveFile(archive, resolvedPath);
  if (entry == null) return BinaryFile.empty();

  final name = entry.name.split('/').last;

  return BinaryFile(
    content: contentBytes(entry),
    name: name,
    type: name.split('.').last,
    path: entry.name,
  );
}
