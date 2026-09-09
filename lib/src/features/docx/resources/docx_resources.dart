import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/docx/container/docx_package.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

/// Binary resources and archive inventory extracted from a DOCX package.
final class DocxResources {
  /// Creates categorized resources and their source archive inventory.
  const DocxResources({
    required this.images,
    required this.fonts,
    required this.others,
    required this.archiveEntries,
  });

  /// Image resources referenced or stored under the media directory.
  final List<BinaryFile> images;

  /// Embedded font resources.
  final List<BinaryFile> fonts;

  /// Remaining non-XML binary resources.
  final List<BinaryFile> others;

  /// File inventory for the decoded package.
  final List<ArchiveEntry> archiveEntries;
}

/// Extracts categorized binary resources while preserving archive order.
DocxResources readDocxResources(final Archive archive, final Set<String> referencedImages) {
  final images = _readImages(archive, referencedImages);
  final fonts = _readFonts(archive);
  final others = _readOtherBinaryParts(archive, images, fonts);

  return DocxResources(
    images: images,
    fonts: fonts,
    others: others,
    archiveEntries: _archiveEntries(archive),
  );
}

List<BinaryFile> _readImages(final Archive archive, final Set<String> referencedImages) {
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = normalizeDocxPartPath(entry.name);
    final underMedia = path.toLowerCase().startsWith('word/media/');
    final referenced = referencedImages.any(
      (final target) => target.toLowerCase() == path.toLowerCase(),
    );
    if (!referenced && (!underMedia || !_isImagePath(path))) continue;
    result.add(_binaryFile(path, docxEntryBytes(entry)));
  }

  return result;
}

List<BinaryFile> _readFonts(final Archive archive) {
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = normalizeDocxPartPath(entry.name);
    if (!path.toLowerCase().startsWith('word/fonts/') || !_isFontPath(path)) continue;
    result.add(_binaryFile(path, docxEntryBytes(entry)));
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
    final path = normalizeDocxPartPath(entry.name);
    final lower = path.toLowerCase();
    if (known.contains(lower) || lower.endsWith('.xml') || lower.endsWith('.rels')) continue;
    result.add(_binaryFile(path, docxEntryBytes(entry)));
  }

  return result;
}

List<ArchiveEntry> _archiveEntries(final Archive archive) => <ArchiveEntry>[
  for (final entry in archive.files)
    if (entry.isFile) ArchiveEntry(path: normalizeDocxPartPath(entry.name), size: entry.size),
];

bool _isImagePath(final String path) {
  final lower = path.toLowerCase();

  return lower.endsWith('.bmp') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.svg') ||
      lower.endsWith('.tif') ||
      lower.endsWith('.tiff') ||
      lower.endsWith('.webp');
}

bool _isFontPath(final String path) {
  final lower = path.toLowerCase();

  return lower.endsWith('.otf') ||
      lower.endsWith('.ttf') ||
      lower.endsWith('.woff') ||
      lower.endsWith('.woff2');
}

BinaryFile _binaryFile(final String path, final List<int> bytes) {
  final name = path.split('/').last;

  return BinaryFile(
    content: bytes is Uint8List ? Uint8List.sublistView(bytes) : Uint8List.fromList(bytes),
    name: name,
    type: name.contains('.') ? name.split('.').last.toLowerCase() : '',
    path: path,
  );
}
