import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';

import '../../foundation/archive/archive_access.dart';
import '../../foundation/entities/entities.dart';
import 'container/epub_root_file.dart';
import 'content/epub_files.dart';
import 'content/epub_viewports.dart';
import 'encryption/epub_encryption.dart';
import 'entities/entities.dart';
import 'exceptions/exceptions.dart';
import 'metadata/epub_cover.dart';
import 'metadata/epub_metadata.dart';
import 'navigation/epub_navigation.dart';
import 'package/parse_epub_package.dart';

export 'container/epub_root_file.dart';

/// Parses an EPUB from raw [bytes].
EpubBook parseEpubBook(final Uint8List bytes) {
  return parseEpubArchive(decodeBookZip(bytes));
}

/// Parses an already decoded EPUB [archive] into an [EpubBook].
///
/// When [rootFilePath] is omitted, the path is read from
/// `META-INF/container.xml` and then recovered by scanning valid `.opf`
/// entries when the container is absent or unusable. A caller that already
/// selected a package can pass its archive-relative path explicitly.
EpubBook parseEpubArchive(final Archive archive, {final String? rootFilePath}) {
  final (path: selectedRootFilePath, package: package) = _readPackage(archive, rootFilePath);
  final navigationSections = getEpubNavigationSections(package, archive, selectedRootFilePath);
  final encryption = EpubEncryption.fromArchive(archive, package);
  final files = extractFiles(
    archive.files,
    package.manifest.items,
    selectedRootFilePath,
    encryption,
  );
  final cover = getBookCover(package, archive, files.images, selectedRootFilePath);
  final spine = _resolveSpine(package, files, selectedRootFilePath);
  final spinePaths = spine == null ? null : List<String>.of(spine.paths);
  final contentViewports = extractContentViewports(files.html, spine?.paths ?? const <String>[]);

  return EpubBook(
    navigation: navigationSections.toc,
    pageList: navigationSections.pageList,
    landmarks: navigationSections.landmarks,
    files: files,
    cover: cover,
    package: package,
    spinePaths: spinePaths,
    spineIdrefs: spine == null ? null : List<String>.of(spine.idrefs),
    contentViewports: contentViewports,
    nonLinearSpinePaths: spine == null
        ? const <String>{}
        : <String>{
            for (var index = 0; index < spine.paths.length; index++)
              if (package.spine.nonLinearIdrefs.contains(spine.idrefs[index])) spine.paths[index],
          },
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
  final (path: selectedRootFilePath, package: package) = _readPackage(archive, rootFilePath);
  EpubEncryption.fromArchive(archive, package);

  return epubBookMetadata(package, getBookCover(package, archive, const [], selectedRootFilePath));
}

({String path, EpubPackage package}) _readPackage(
  final Archive archive,
  final String? requestedRootFilePath,
) {
  final path = _selectRootFilePath(archive, requestedRootFilePath);
  final rootFile = findArchiveFile(archive, path);
  if (rootFile == null) throw EpubException('No root file found at $path');

  return (path: path, package: parsePackageBytes(rootFile.content as List<int>));
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

/// The spine resolved against the extracted content files: parallel
/// content paths and manifest idrefs in reading order, using the
/// `files.html` path space. Null when no spine item resolves to a
/// content document.
({List<String> paths, List<String> idrefs})? _resolveSpine(
  final EpubPackage package,
  final Files files,
  final String? rootFilePath,
) {
  final htmlPaths = files.html
      .map((final file) => normalizeZipPath(file.path).toLowerCase())
      .toList();
  final paths = <String>[];
  final idrefs = <String>[];
  for (final idref in package.spine.items) {
    final item = package.manifest.items.firstWhereOrNull(
      (final candidate) => candidate.id == idref,
    );
    if (item == null) continue;

    final path = normalizeZipPath(resolveItemPath(rootFilePath, item.path));
    final index = htmlPaths.indexOf(path.toLowerCase());
    if (index >= 0) {
      paths.add(files.html[index].path);
      idrefs.add(idref);
    }
  }

  return paths.isEmpty ? null : (paths: paths, idrefs: idrefs);
}
