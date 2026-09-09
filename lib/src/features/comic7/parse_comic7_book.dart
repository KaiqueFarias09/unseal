import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/comic/entities/entities.dart';
import 'package:e_livre/src/features/comic/metadata/comic_info.dart';
import 'package:e_livre/src/features/comic/parse_comic_book.dart';
import 'package:e_livre/src/features/comic7/exceptions/exceptions.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/images/cover_helpers.dart';
import 'package:e_livre/src/foundation/text/document_encoding.dart';
import 'package:e_livre/src/foundation/utils/archive_utils.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';
import 'package:koni_archive/koni_archive.dart' as koni;

/// Maximum decoded size accepted for one CB7 entry.
const int maxComic7EntryBytes = 128 << 20;

/// Parses a CB7 (7-Zip comic) archive.
///
/// Koni's archive reader is asynchronous because 7z decompression is
/// streaming-first. Callers that need the synchronous legacy API can keep
/// using [parseComicBook] for CBZ/CBR; CB7/CBC are exposed through this
/// asynchronous entry point and through `BookReader.openFromBytes`.
Future<ComicBook> parseComic7Book(final Uint8List bytes) async {
  if (!_isSevenZip(bytes)) throw const Comic7Exception('Input is not a 7-Zip archive.');

  final archive = await _openArchive(bytes);
  try {
    return await _parseComic7Archive(archive);
  } finally {
    await archive.close();
  }
}

/// Reads ComicInfo.xml metadata from a CB7 archive.
Future<BookMetadata> readComic7Metadata(final Uint8List bytes) async {
  if (!_isSevenZip(bytes)) throw const Comic7Exception('Input is not a 7-Zip archive.');

  final archive = await _openArchive(bytes);
  try {
    final info = await _readComicInfo(archive);
    return _metadata(info, BookFormat.cb7);
  } finally {
    await archive.close();
  }
}

/// Parses a CBC collection and concatenates its comics in comics.txt order.
///
/// Calibre treats each non-empty line as `path[:title]`, replacing `#` in
/// paths before resolving it inside the collection. The title is used by
/// Calibre for the generated TOC; the common eLivre comic model has one
/// flat page sequence, so the first declared title is retained as the
/// collection title while all pages remain in declaration order.
Future<ComicBook> parseCbcBook(final Uint8List bytes) async {
  final archive = _decodeZip(bytes);
  final listing = _findTopLevelEntry(archive, 'comics.txt');
  if (listing == null) {
    throw const InvalidCbcCollectionException('CBC collection has no comics.txt.');
  }

  final comics = _readCollectionLines(contentBytes(listing));
  if (comics.isEmpty) {
    throw const InvalidCbcCollectionException('CBC collection has no comics.');
  }

  final pages = <BinaryFile>[];
  BookMetadata? firstMetadata;
  String? firstTitle;
  for (final comic in comics) {
    final entry = findArchiveFile(archive, comic.path);
    if (entry == null) continue;
    final nested = contentBytes(entry);
    final parsed = await _parseNestedComic(nested, entry.name);
    firstMetadata ??= parsed.metadata;
    firstTitle ??= comic.title;
    pages.addAll(parsed.pages);
  }
  if (pages.isEmpty) {
    throw const Comic7PagesNotFoundException('CBC collection has no readable comic pages.');
  }

  return _buildComic(
    pages,
    firstMetadata,
    BookFormat.cbc,
    titleOverride: comics.length == 1 ? firstMetadata?.title : firstTitle ?? 'Comic collection',
  );
}

/// Reads metadata from a CBC collection using the same page-resolution path
/// as [parseCbcBook].
Future<BookMetadata> readCbcMetadata(final Uint8List bytes) async {
  final book = await parseCbcBook(bytes);
  return book.metadata;
}

Future<koni.Archive> _openArchive(final Uint8List bytes) async {
  try {
    return await koni.Archive.openBytes(bytes);
  } on Object catch (error) {
    throw Comic7Exception('Unable to open 7-Zip archive: $error');
  }
}

Future<ComicBook> _parseComic7Archive(final koni.Archive archive) async {
  final pages = <BinaryFile>[];
  ComicInfo? comicInfo;
  for (final entry in archive.entries) {
    if (!entry.isFile) continue;
    final lower = entry.path.toLowerCase();
    if (_isComicInfoPath(lower)) {
      final data = await _readEntry(archive, entry);
      comicInfo = ComicInfo.parse(convert.utf8.decode(data, allowMalformed: true)) ?? comicInfo;
      continue;
    }
    if (!_isImagePath(lower) && lower.contains('.')) continue;
    final data = await _readEntry(archive, entry);
    final type = sniffImageType(data);
    if (type == null) continue;
    pages.add(
      BinaryFile(
        content: data,
        name: entry.path.split('/').last,
        type: type.fileExtension,
        path: entry.path,
      ),
    );
  }
  if (pages.isEmpty) {
    throw const Comic7PagesNotFoundException('CB7 archive has no readable image pages.');
  }

  pages.sort((final a, final b) => compareNatural(a.path, b.path));
  return _buildComic(pages, comicInfo?.metadata, BookFormat.cb7);
}

Future<Uint8List> _readEntry(final koni.Archive archive, final koni.ArchiveEntry entry) async {
  try {
    return await archive.readBytes(entry, maxSize: maxComic7EntryBytes);
  } on Object catch (error) {
    throw Comic7Exception('Unable to read CB7 entry "${entry.path}": $error');
  }
}

Future<ComicBook> _parseNestedComic(final Uint8List bytes, final String path) async {
  if (_isSevenZip(bytes)) return parseComic7Book(bytes);
  if (_isZip(bytes) || _isRar(bytes)) return parseComicBook(bytes);

  throw InvalidCbcCollectionException('Unsupported nested comic format: $path');
}

Future<ComicInfo?> _readComicInfo(final koni.Archive archive) async {
  for (final entry in archive.entries) {
    if (!entry.isFile || !_isComicInfoPath(entry.path.toLowerCase())) continue;
    final data = await _readEntry(archive, entry);
    return ComicInfo.parse(convert.utf8.decode(data, allowMalformed: true));
  }

  return null;
}

ComicBook _buildComic(
  final List<BinaryFile> pages,
  final BookMetadata? sourceMetadata,
  final BookFormat format, {
  final String? titleOverride,
}) {
  final cover = pages.first;
  var metadata = sourceMetadata ?? BookMetadata(format: format);
  metadata = metadata.copyWith(format: format, title: titleOverride, cover: coverFromBinary(cover));

  return ComicBook(cover: cover, metadata: metadata, pages: pages, format: format);
}

BookMetadata _metadata(final ComicInfo? info, final BookFormat format) =>
    (info?.metadata ?? BookMetadata(format: format)).copyWith(format: format);

List<_CollectionComic> _readCollectionLines(final List<int> bytes) {
  final source = decodeDocumentText(bytes);
  final result = <_CollectionComic>[];
  for (final rawLine in source.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final separator = line.indexOf(':');
    final rawPath = separator < 0 ? line : line.substring(0, separator);
    final declaredTitle = separator < 0 ? '' : line.substring(separator + 1).trim();
    final path = normalizeZipPath(rawPath.replaceAll('#', '_'));
    if (path.isEmpty) continue;
    final title = declaredTitle.isEmpty ? path.split('/').last.split('.').first : declaredTitle;
    result.add(_CollectionComic(path, title));
  }

  return result;
}

Archive _decodeZip(final Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } on Object catch (error) {
    throw InvalidCbcCollectionException('CBC collection is not a valid ZIP archive: $error');
  }
}

ArchiveFile? _findTopLevelEntry(final Archive archive, final String name) {
  final normalizedName = name.toLowerCase();
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final normalizedPath = normalizeZipPath(entry.name).toLowerCase();
    if (normalizedPath == normalizedName && !normalizedPath.contains('/')) return entry;
  }

  return null;
}

bool _isSevenZip(final List<int> bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 0x37 &&
    bytes[1] == 0x7a &&
    bytes[2] == 0xbc &&
    bytes[3] == 0xaf &&
    bytes[4] == 0x27 &&
    bytes[5] == 0x1c;

bool _isZip(final List<int> bytes) => bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b;

bool _isRar(final List<int> bytes) =>
    bytes.length >= 7 &&
    bytes[0] == 0x52 &&
    bytes[1] == 0x61 &&
    bytes[2] == 0x72 &&
    bytes[3] == 0x21 &&
    bytes[4] == 0x1a &&
    bytes[5] == 0x07;

bool _isComicInfoPath(final String path) => path.split('/').last == 'comicinfo.xml';

bool _isImagePath(final String path) => _imageExtensions.contains(_extension(path));

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
  'tif',
  'tiff',
  'webp',
};

final class _CollectionComic {
  const _CollectionComic(this.path, this.title);

  final String path;
  final String title;
}
