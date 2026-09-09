import 'package:archive/archive.dart';
import 'package:e_livre/src/features/odt/container/odt_package.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/files/book_file_factory.dart';
import 'package:e_livre/src/foundation/images/cover_helpers.dart';
import '../../../foundation/archive/archive_access.dart';
import '../../../foundation/images/image_type_sniffer.dart';

/// Binary resources and inventory extracted from an ODT package.
final class OdtResources {
  /// Creates a complete ODT resource bundle.
  const OdtResources({
    required this.images,
    required this.fonts,
    required this.others,
    required this.archiveEntries,
    required this.cover,
  });

  /// Extracts categorized binary resources from [package].
  factory OdtResources.fromPackage(
    final OdtPackage package, {
    required final Set<String> referencedImages,
  }) {
    final images = _readImages(package.archive, referencedImages);
    final fonts = _readFonts(package.archive);
    final others = _readOtherBinaryParts(package.archive, images, fonts);

    return OdtResources(
      images: images,
      fonts: fonts,
      others: others,
      archiveEntries: _archiveEntries(package.archive),
      cover: firstImageCover(images),
    );
  }

  /// Image parts in package order.
  final List<BinaryFile> images;

  /// Embedded font parts in package order.
  final List<BinaryFile> fonts;

  /// Remaining non-XML binary parts in package order.
  final List<BinaryFile> others;

  /// Normalized inventory of files stored in the package.
  final List<ArchiveEntry> archiveEntries;

  /// First package image when one exists.
  final BinaryFile? cover;
}

List<BinaryFile> _readImages(final Archive archive, final Set<String> referencedImages) {
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = normalizeZipPath(entry.name);
    final lower = path.toLowerCase();
    final content = contentBytes(entry);
    final isImage =
        lower.startsWith('pictures/') &&
        (sniffImageType(content) != null || _imageExtensions.contains(_extension(path)));
    if (!isImage) continue;
    if (referencedImages.isNotEmpty &&
        !_containsPath(referencedImages, path) &&
        !lower.startsWith('pictures/')) {
      continue;
    }
    result.add(binaryFile(path, content));
  }

  return result;
}

List<BinaryFile> _readFonts(final Archive archive) {
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = normalizeZipPath(entry.name);
    if (!path.toLowerCase().startsWith('fonts/')) continue;
    result.add(binaryFile(path, contentBytes(entry)));
  }

  return result;
}

List<BinaryFile> _readOtherBinaryParts(
  final Archive archive,
  final List<BinaryFile> images,
  final List<BinaryFile> fonts,
) {
  final known = <String>{
    ...images.map((final file) => file.path.toLowerCase()),
    ...fonts.map((final file) => file.path.toLowerCase()),
  };
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = normalizeZipPath(entry.name);
    final lower = path.toLowerCase();
    if (known.contains(lower) || lower.endsWith('.xml') || lower == 'mimetype') continue;
    result.add(binaryFile(path, contentBytes(entry)));
  }

  return result;
}

List<ArchiveEntry> _archiveEntries(final Archive archive) => <ArchiveEntry>[
  for (final entry in archive.files)
    if (entry.isFile) ArchiveEntry(path: normalizeZipPath(entry.name), size: entry.size),
];

bool _containsPath(final Set<String> paths, final String path) =>
    paths.any((final candidate) => normalizeZipPath(candidate).toLowerCase() == path.toLowerCase());

String _extension(final String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

const _imageExtensions = <String>{
  'avif',
  'bmp',
  'gif',
  'jpeg',
  'jpg',
  'png',
  'svg',
  'tif',
  'tiff',
  'webp',
};
