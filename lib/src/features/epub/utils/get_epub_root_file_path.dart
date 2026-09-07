import 'package:archive/archive.dart';
import 'package:e_livre/src/features/epub/constants/epub_constants.dart' as epub_constants;
import 'package:e_livre/src/features/epub/exceptions/exceptions.dart';
import 'package:e_livre/src/features/epub/utils/archive_utils.dart';
import 'package:e_livre/src/features/epub/utils/parse_epub_package.dart';
import 'package:e_livre/src/features/epub/utils/xml_utils.dart';
import 'package:xml/xml.dart';

/// Retrieves the root file path of the EPUB from the provided archive.
///
/// The function first gets the container file entry from the archive, then parses it into an XML document.
/// It then gets the package element from the container document and retrieves the root file path from the package.
///
/// [epubArchive] is the archive from which to retrieve the root file path.
///
/// Returns the root file path of the EPUB, or `null` if the root file path could not be found.
String? getEpubRootFilePath(final Archive epubArchive) {
  final containerFileEntry = _getContainerFileEntry(epubArchive);
  final containerDocument = parseEpubXml(containerFileEntry.content as List<int>);
  final package = _getPackageElement(containerDocument);

  return _getRootFilePath(package, epubArchive);
}

/// Finds a usable OPF package path in [epubArchive].
///
/// The normal EPUB path comes from `META-INF/container.xml`. For recovery of
/// ZIP archives that omit that entry, this function scans `.opf` entries and
/// keeps only packages that can be parsed by eLivre. It returns `null` when
/// the archive contains no usable EPUB package.
String? findEpubRootFilePath(final Archive epubArchive) {
  try {
    final rootFilePath = getEpubRootFilePath(epubArchive);
    if (rootFilePath != null) return rootFilePath;
  } on Exception {
    // A missing or malformed container is recoverable when the archive still
    // contains a valid package document.
  }

  for (final entry in epubArchive.files) {
    if (!entry.isFile || !entry.name.toLowerCase().endsWith('.opf')) continue;

    final path = normalizeZipPath(entry.name);
    try {
      parsePackageBytes(entry.content as List<int>);
      return path;
    } on Exception {
      // Continue past unrelated or malformed OPF-looking entries.
    }
  }

  return null;
}

ArchiveFile _getContainerFileEntry(final Archive epubArchive) {
  return findArchiveFile(epubArchive, epub_constants.containerFilepath) ??
      (throw EpubException(
        'EPUB parsing error: ${epub_constants.containerFilepath} '
        'file not found in archive.',
      ));
}

XmlElement _getPackageElement(final XmlDocument containerDocument) {
  final package = containerDocument
      .findElements('container', namespace: epub_constants.containerNamespace)
      .firstOrNull;
  if (package == null) throw EpubException('EPUB parsing error: Invalid epub container');

  return package;
}

String? _getRootFilePath(final XmlElement package, final Archive archive) {
  final rootFileElements = package.descendants.whereType<XmlElement>().where(
    (final element) => element.name.local == 'rootfile',
  );
  if (rootFileElements.isEmpty) {
    throw EpubException('EPUB parsing error: rootfile element not found in container file');
  }

  for (final rootFileElement in rootFileElements) {
    final fullPath = rootFileElement.getAttribute('full-path')?.trim();
    if (fullPath == null || fullPath.isEmpty) continue;

    final mediaType = rootFileElement.getAttribute('media-type')?.trim().toLowerCase();
    final isPackage = mediaType == null || mediaType == 'application/oebps-package+xml';
    if (!isPackage) continue;

    final normalizedPath = normalizeZipPath(fullPath);
    final entry = findArchiveFile(archive, normalizedPath);
    if (entry == null) continue;

    try {
      parsePackageBytes(entry.content as List<int>);
      return normalizedPath;
    } on Exception {
      // Try a later rootfile when this candidate is not a usable package.
    }
  }

  throw EpubException('EPUB parsing error: no usable rootfile found in container file');
}
