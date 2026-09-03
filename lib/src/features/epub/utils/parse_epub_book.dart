import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/src/foundation/entities/book/files.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';
import 'package:e_livre/src/features/epub/entities/book/book.dart';
import 'package:e_livre/src/features/epub/entities/package/epub_package.dart';
import 'package:e_livre/src/features/epub/exceptions/epub_exception.dart';
import 'package:e_livre/src/features/epub/utils/archive_utils.dart';
import 'package:e_livre/src/features/epub/utils/epub_metadata_mapper.dart';
import 'package:e_livre/src/features/epub/utils/extract_files.dart';
import 'package:e_livre/src/features/epub/utils/get_book_cover.dart';
import 'package:e_livre/src/features/epub/utils/get_epub_root_file_path.dart';
import 'package:e_livre/src/features/epub/utils/parse_epub_package.dart';
import 'package:e_livre/src/features/epub/utils/process_package.dart';

/// Parses an EPUB from raw [bytes].
EpubBook parseEpubBook(final Uint8List bytes) {
  return parseEpubArchive(ZipDecoder().decodeBytes(bytes));
}

/// Parses an already decoded EPUB [archive] into an [EpubBook].
EpubBook parseEpubArchive(final Archive archive) {
  final rootFilePath = getEpubRootFilePath(archive);
  final rootFile = _getRootFile(archive, rootFilePath).content as List<int>;

  final package = parsePackage(convert.utf8.decode(rootFile));
  final navigation = getEpubNavigation(package, archive, rootFilePath);

  final files = extractFiles(
    archive.files,
    package.manifest.items,
    rootFilePath,
  );
  final cover = getBookCover(package, archive, files.images, rootFilePath);

  return EpubBook(
    navigation: navigation,
    files: files,
    cover: cover,
    package: package,
    spinePaths: _spinePaths(package, files, rootFilePath),
  );
}

/// Reads only the metadata of an EPUB [archive].
///
/// Decodes the OPF package and, at most, the single cover entry —
/// the rest of the archive is never inflated.
BookMetadata readEpubMetadata(final Archive archive) {
  final rootFilePath = getEpubRootFilePath(archive);
  final rootFile = _getRootFile(archive, rootFilePath).content as List<int>;

  final package = parsePackage(convert.utf8.decode(rootFile));
  return epubBookMetadata(
    package,
    getBookCover(package, archive, const [], rootFilePath),
  );
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
    if (index >= 0) {
      resolved.add(files.html[index].path);
    }
  }
  return resolved.isEmpty ? null : resolved;
}
