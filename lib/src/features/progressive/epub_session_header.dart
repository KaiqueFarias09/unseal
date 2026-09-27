import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/archive/archive_access.dart';
import '../../foundation/archive/zip_random_access.dart';
import '../../foundation/entities/entities.dart';
import '../epub/codec/epub_xml.dart';
import '../epub/container/epub_root_file.dart';
import '../epub/content/epub_files.dart';
import '../epub/content/epub_viewports.dart';
import '../epub/encryption/epub_encryption.dart';
import '../epub/entities/entities.dart';
import '../epub/exceptions/exceptions.dart';
import '../epub/metadata/epub_cover.dart';
import '../epub/navigation/epub_navigation.dart';
import '../epub/package/parse_epub_package.dart';
import 'session_policy.dart';

const _containerEntryPath = 'META-INF/container.xml';
const _encryptionEntryPath = 'META-INF/encryption.xml';

/// Builds the session header of an EPUB: a real [EpubBook] whose
/// structure is complete (metadata, navigation, spine, rendition data,
/// container inventory) while the file set stays empty.
///
/// Only small container documents are inflated — container.xml, the OPF,
/// navigation documents, encryption.xml, the cover (bounded by
/// [SessionPolicy.coverMaxBytes]) and the content documents of
/// pre-paginated spine items for viewport extraction. Everything else
/// loads on demand through the session.
///
/// Semantics follow the eager `parseEpubArchive` with two documented
/// deltas: the
/// cover is dropped (empty) when it exceeds the policy cap, and
/// [EpubBook.contentViewports] only holds pre-paginated documents —
/// reflowable documents declaring a `<meta name="viewport">` in their
/// content are absent, and nothing in the reading pipeline consults
/// viewports for reflowable items.
EpubBook buildEpubSessionHeader(
  final ZipRandomAccess source, {
  final String? rootFilePath,
  final SessionPolicy policy = const SessionPolicy(),
}) {
  final partial = _PartialArchive(source);
  final selectedRootFilePath = _selectRootFilePath(source, partial, rootFilePath);
  final (path: _, package: package) = _readPackage(source, partial, selectedRootFilePath);
  _inflateNavigationEntries(source, partial, package, selectedRootFilePath);
  final navigationSections = getEpubNavigationSections(
    package,
    partial.archive,
    selectedRootFilePath,
  );

  EpubEncryption? encryption;
  final encryptionRecord = source.find(_encryptionEntryPath);
  if (encryptionRecord != null) {
    partial.add(_encryptionEntryPath);
    encryption = EpubEncryption.fromArchive(partial.archive, package);
  }

  final spine = _resolveSpine(source, package, selectedRootFilePath);
  final cover = _loadCover(source, package, selectedRootFilePath, policy);
  final contentViewports = _extractPrePaginatedViewports(source, package, spine, encryption);

  return EpubBook(
    navigation: navigationSections.toc,
    pageList: navigationSections.pageList,
    landmarks: navigationSections.landmarks,
    files: Files.empty(),
    cover: cover,
    package: package,
    spinePaths: spine == null ? null : List<String>.of(spine.paths),
    spineIdrefs: spine == null ? null : List<String>.of(spine.idrefs),
    contentViewports: contentViewports,
    nonLinearSpinePaths: spine == null
        ? const <String>{}
        : <String>{
            for (var index = 0; index < spine.paths.length; index++)
              if (package.spine.nonLinearIdrefs.contains(spine.idrefs[index])) spine.paths[index],
          },
    archiveEntries: _archiveEntries(source),
  );
}

({String path, EpubPackage package}) _readPackage(
  final ZipRandomAccess source,
  final _PartialArchive partial,
  final String selectedRootFilePath,
) {
  final record = source.find(selectedRootFilePath);
  if (record == null) throw EpubException('No root file found at $selectedRootFilePath');

  final bytes = partial.add(selectedRootFilePath);

  return (path: selectedRootFilePath, package: parsePackageBytes(bytes as List<int>));
}

String _selectRootFilePath(
  final ZipRandomAccess source,
  final _PartialArchive partial,
  final String? rootFilePath,
) {
  if (rootFilePath != null) {
    final normalized = normalizeZipPath(rootFilePath);
    if (source.find(normalized) != null) return normalized;

    throw EpubException('No root file found at $normalized');
  }

  final containerRecord = source.find(_containerEntryPath);
  if (containerRecord != null) partial.add(_containerEntryPath);
  if (source.find(_containerEntryPath) == null || findEpubRootFilePath(partial.archive) == null) {
    // Container absent or unusable: recover by scanning every .opf
    // entry, like the eager path does.
    for (final record in source.entries) {
      if (record.isFile && record.name.toLowerCase().endsWith('.opf')) partial.add(record.name);
    }
  }
  final discovered = findEpubRootFilePath(partial.archive);
  if (discovered != null) return discovered;

  throw EpubException('No usable EPUB package found');
}

/// Inflates the navigation documents the nav reader may look up: every
/// manifest item flagged `properties="nav"`, every NCX item, and the
/// spine's declared `toc` — the same candidate order the reader itself
/// walks.
void _inflateNavigationEntries(
  final ZipRandomAccess source,
  final _PartialArchive partial,
  final EpubPackage package,
  final String? rootFilePath,
) {
  final candidatePaths = <String>{};
  void consider(final ManifestItem? item) {
    if (item == null) return;
    if (item.properties.any((final property) => property.toLowerCase() == 'nav') ||
        item.mediaType.split(';').first.trim().toLowerCase() == 'application/x-dtbncx+xml') {
      candidatePaths.add(resolveItemPath(rootFilePath, item.path));
    }
  }

  if (package is Epub3Package) consider(_itemById(package, package.tocId));
  consider(_itemById(package, package.spine.tocId));
  for (final item in package.manifest.items) {
    consider(item);
  }

  for (final candidate in candidatePaths) {
    if (source.find(candidate) != null) partial.add(candidate);
  }
}

ManifestItem? _itemById(final EpubPackage package, final String? id) {
  if (id == null) return null;

  for (final item in package.manifest.items) {
    if (item.id == id) return item;
  }

  return null;
}

/// Resolves the spine against the container inventory the way
/// `parseEpubArchive` resolves it against extracted HTML: a spine item
/// joins the reading order when its manifest item classifies as an HTML
/// content document and its entry exists.
({List<String> paths, List<String> idrefs})? _resolveSpine(
  final ZipRandomAccess source,
  final EpubPackage package,
  final String? rootFilePath,
) {
  final htmlPaths = <String>{};
  for (final item in package.manifest.items) {
    if (!isHtmlManifestItem(item)) continue;

    final path = normalizeZipPath(resolveItemPath(rootFilePath, item.path));
    final record = source.find(path);
    if (record != null) htmlPaths.add(path.toLowerCase());
  }

  final paths = <String>[];
  final idrefs = <String>[];
  for (final idref in package.spine.items) {
    final item = _itemById(package, idref);
    if (item == null) continue;
    if (!isHtmlManifestItem(item)) continue;

    final path = normalizeZipPath(resolveItemPath(rootFilePath, item.path));
    final record = source.find(path);
    if (record == null) continue;
    if (!htmlPaths.contains(path.toLowerCase())) continue;

    paths.add(record.name);
    idrefs.add(idref);
  }

  return paths.isEmpty ? null : (paths: paths, idrefs: idrefs);
}

/// Inflates the cover entry unless it exceeds the policy cap; an
/// oversized cover yields an empty cover file, mirroring "no cover".
BinaryFile _loadCover(
  final ZipRandomAccess source,
  final EpubPackage package,
  final String? rootFilePath,
  final SessionPolicy policy,
) {
  final coverItem = resolveCoverItem(package);
  if (coverItem == null) return BinaryFile.empty();

  final resolvedPath = resolveItemPath(rootFilePath, coverItem.path);
  final record = source.find(resolvedPath);
  if (record == null) return BinaryFile.empty();
  if (record.uncompressedSize > policy.coverMaxBytes) return BinaryFile.empty();

  final bytes = source.inflate(record);
  final name = record.name.split('/').last;
  final dot = name.lastIndexOf('.');

  return BinaryFile(
    content: bytes,
    name: name,
    type: dot < 0 || dot == name.length - 1 ? '' : name.substring(dot + 1),
    path: record.name,
  );
}

/// Viewports of pre-paginated spine documents, extracted from their
/// content; reflowable documents are not inflated here.
Map<String, EpubViewport> _extractPrePaginatedViewports(
  final ZipRandomAccess source,
  final EpubPackage package,
  final ({List<String> paths, List<String> idrefs})? spine,
  final EpubEncryption? encryption,
) {
  if (spine == null) return const <String, EpubViewport>{};
  if (package is! Epub3Package) return const <String, EpubViewport>{};

  final files = <TextFile>[];
  for (var index = 0; index < spine.paths.length; index++) {
    final idref = spine.idrefs[index];
    if (package.renditionSettings.layoutFor(idref) != EpubLayout.prePaginated) continue;

    final record = source.find(spine.paths[index]);
    if (record == null) continue;

    final bytes = _inflateDecrypting(source, record, encryption);
    files.add(TextFile(content: decodeEpubText(bytes), name: '', type: '', path: record.name));
  }

  if (files.isEmpty) return const <String, EpubViewport>{};

  return extractContentViewports(files, spine.paths);
}

/// Container inventory in the same (path, uncompressed-size) shape the
/// eager parse records.
List<ArchiveEntry> _archiveEntries(final ZipRandomAccess source) {
  return <ArchiveEntry>[
    for (final record in source.entries)
      if (record.isFile)
        ArchiveEntry(path: normalizeZipPath(record.name), size: record.uncompressedSize),
  ];
}

Uint8List _inflateDecrypting(
  final ZipRandomAccess source,
  final ZipEntryRecord record,
  final EpubEncryption? encryption,
) {
  final bytes = source.inflate(record);
  if (encryption == null) return bytes;

  return encryption.decodeFont(_asArchiveFile(record, bytes));
}

ArchiveFile _asArchiveFile(final ZipEntryRecord record, final Uint8List bytes) {
  return ArchiveFile.bytes(record.name, bytes);
}

/// Inflates container documents lazily, once each, into a small
/// [Archive] handed to the unmodified EPUB readers.
final class _PartialArchive {
  _PartialArchive(this._source);

  final ZipRandomAccess _source;
  final Archive archive = Archive();
  final Set<String> _added = <String>{};

  Uint8List add(final String path) {
    final normalized = normalizeZipPath(path);
    final existing = _added.lookup(normalized);
    if (existing != null) return contentBytes(findArchiveFile(archive, normalized)!);

    final record = _source.find(normalized);
    if (record == null) throw EpubException('Container entry $normalized is missing.');

    final bytes = _source.inflate(record);
    final materialized = ArchiveFile.bytes(record.name, bytes)
      ..isFile = record.isFile
      ..crc32 = record.crc32;
    archive.addFile(materialized);
    _added.add(normalized);

    return bytes;
  }
}
