import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/src/features/epub/container/epub_root_file.dart';
import 'package:e_livre/src/features/epub/content/epub_files.dart';
import 'package:e_livre/src/features/epub/encryption/epub_encryption.dart';
import 'package:e_livre/src/features/epub/entities/entities.dart';
import 'package:e_livre/src/features/epub/exceptions/exceptions.dart';
import 'package:e_livre/src/features/epub/metadata/epub_cover.dart';
import 'package:e_livre/src/features/epub/metadata/epub_metadata.dart';
import 'package:e_livre/src/features/epub/navigation/epub_navigation.dart';
import 'package:e_livre/src/features/epub/package/parse_epub_package.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/archive_utils.dart';

export 'container/epub_root_file.dart';

/// Parses an EPUB from raw [bytes].
EpubBook parseEpubBook(final Uint8List bytes) {
  return parseEpubArchive(ZipDecoder().decodeBytes(bytes));
}

/// Parses an already decoded EPUB [archive] into an [EpubBook].
///
/// When [rootFilePath] is omitted, the path is read from
/// `META-INF/container.xml` and then recovered by scanning valid `.opf`
/// entries when the container is absent or unusable. A caller that already
/// selected a package can pass its archive-relative path explicitly.
EpubBook parseEpubArchive(final Archive archive, {final String? rootFilePath}) {
  final selectedRootFilePath = _selectRootFilePath(archive, rootFilePath);
  final rootFile = _getRootFile(archive, selectedRootFilePath).content as List<int>;
  final package = parsePackageBytes(rootFile);
  final navigation = getEpubNavigation(package, archive, selectedRootFilePath);
  final encryption = EpubEncryption.fromArchive(archive, package);
  final files = extractFiles(
    archive.files,
    package.manifest.items,
    selectedRootFilePath,
    encryption,
  );
  final cover = getBookCover(package, archive, files.images, selectedRootFilePath);

  return EpubBook(
    navigation: navigation,
    files: files,
    cover: cover,
    package: package,
    spinePaths: _spinePaths(package, files, selectedRootFilePath),
    archiveEntries: _archiveEntries(archive),
  );
}

/// The physical inventory of the container: every file entry of the
/// zip, manifest-independent.
List<ArchiveEntry> _archiveEntries(final Archive archive) {
  return <ArchiveEntry>[
    for (final file in archive.files)
      if (file.isFile) ArchiveEntry(path: normalizeZipPath(file.name), size: file.size),
  ];
}

/// Reads only the metadata of an EPUB [archive].
///
/// Decodes the OPF package and, at most, the single cover entry —
/// the rest of the archive is never inflated. [rootFilePath] has the same
/// override and recovery behavior as [parseEpubArchive].
BookMetadata readEpubMetadata(final Archive archive, {final String? rootFilePath}) {
  final selectedRootFilePath = _selectRootFilePath(archive, rootFilePath);
  final rootFile = _getRootFile(archive, selectedRootFilePath).content as List<int>;
  final package = parsePackageBytes(rootFile);
  EpubEncryption.fromArchive(archive, package);

  return epubBookMetadata(package, getBookCover(package, archive, const [], selectedRootFilePath));
}

String _selectRootFilePath(final Archive archive, final String? rootFilePath) {
  if (rootFilePath != null) {
    final normalized = normalizeZipPath(rootFilePath);
    if (findArchiveFile(archive, normalized) != null) return normalized;

    throw EpubException('No root file found at $normalized');
  }

  final discovered = findEpubRootFilePath(archive);
  if (discovered != null) return discovered;

  throw EpubException('No usable EPUB package found');
}

ArchiveFile _getRootFile(final Archive archive, final String? rootFilePath) {
  if (rootFilePath == null) throw EpubException('No root file found');

  final rootFile = findArchiveFile(archive, rootFilePath);

  return rootFile ?? (throw EpubException('No root file found'));
}

List<String>? _spinePaths(
  final EpubPackage package,
  final Files files,
  final String? rootFilePath,
) {
  final htmlPaths = files.html
      .map((final file) => normalizeZipPath(file.path).toLowerCase())
      .toList();
  final resolved = <String>[];

  for (final idref in package.spine.items) {
    final item = package.manifest.items.firstWhereOrNull(
      (final candidate) => candidate.id == idref,
    );
    if (item == null) continue;

    final path = normalizeZipPath(resolveItemPath(rootFilePath, item.path));
    final index = htmlPaths.indexOf(path.toLowerCase());
    if (index >= 0) resolved.add(files.html[index].path);
  }

  return resolved.isEmpty ? null : resolved;
}
