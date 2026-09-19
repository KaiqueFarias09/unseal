import 'dart:convert' as convert;
import 'dart:typed_data';

import '../../foundation/archive/archive_access.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import 'entities/entities.dart';
import 'exceptions/exceptions.dart';
import 'metadata/comic_info.dart';
import 'natural_page_sort.dart';

part 'archive/rar4_decoder.dart';
part 'archive/rar_reader.dart';

/// A comic page candidate extracted from an archive.
class _Page {
  const _Page(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// Parses a comic book (CBZ zip or CBR rar) from raw [bytes].
///
/// Pages at a uniform directory depth are ordered naturally by their full archive path. When an
/// archive mixes directory depths, the page basename is the primary ordering key and the full
/// archive path is the deterministic tie-breaker. This keeps mixed-depth archives in the expected
/// reader order.
ComicBook parseComicBook(final Uint8List bytes) {
  final (:pages, :comicInfo, :format) = _readArchive(bytes);

  return _build(pages, comicInfo, format);
}

/// Reads only the metadata of a comic book from [bytes].
BookMetadata readComicMetadata(final Uint8List bytes) {
  final (pages: _, :comicInfo, :format) = _readArchive(bytes);

  return _metadataFor(comicInfo, format);
}

bool _isZipArchive(final Uint8List bytes) {
  return bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;
}

({List<_Page> pages, ComicInfo? comicInfo, BookFormat format}) _readArchive(final Uint8List bytes) {
  final format = _isZipArchive(bytes) ? BookFormat.cbz : BookFormat.cbr;
  final pages = <_Page>[];
  ComicInfo? comicInfo;
  for (final file in _readArchiveFiles(bytes, format)) {
    if (file.name.toLowerCase() == 'comicinfo.xml') {
      comicInfo =
          ComicInfo.parse(convert.utf8.decode(file.bytes, allowMalformed: true)) ?? comicInfo;
      continue;
    }

    if (sniffImageType(file.bytes) != null) {
      pages.add(_Page(file.name, file.bytes));
    }
  }

  if (pages.isEmpty) throw const ComicException('No image pages found in the comic archive.');

  _sortPages(pages);

  return (pages: pages, comicInfo: comicInfo, format: format);
}

Iterable<({String name, Uint8List bytes})> _readArchiveFiles(
  final Uint8List bytes,
  final BookFormat format,
) sync* {
  if (format == BookFormat.cbz) {
    final archive = decodeBookZip(bytes);
    for (final entry in archive.files) {
      if (!entry.isFile) continue;

      yield (name: entry.name, bytes: Uint8List.sublistView(entry.content));
    }

    return;
  }

  for (final entry in _readRarEntries(bytes)) {
    if (entry.isDirectory) continue;

    if (entry.isCompressed && entry.data.isEmpty) {
      throw ComicException(
        'RAR entry "${entry.name}" is compressed; only stored (uncompressed) '
        'and ordinary RAR 2.9/3.x CBR archives are supported.',
      );
    }

    yield (name: entry.name, bytes: entry.data);
  }
}

void _sortPages(final List<_Page> pages) {
  final depths = pages.map((final page) => _directoryDepth(page.name)).toSet();
  if (depths.length == 1) {
    pages.sort((final a, final b) => compareComicPageNames(a.name, b.name));

    return;
  }

  pages.sort((final a, final b) {
    final basenameOrder = compareComicPageNames(_archiveBasename(a.name), _archiveBasename(b.name));
    if (basenameOrder != 0) return basenameOrder;

    return compareComicPageNames(a.name, b.name);
  });
}

int _directoryDepth(final String path) => '/'.allMatches(path).length;

String _archiveBasename(final String path) {
  final separator = path.lastIndexOf('/');

  return separator == -1 ? path : path.substring(separator + 1);
}

ComicBook _build(final List<_Page> pages, final ComicInfo? comicInfo, final BookFormat format) {
  final images = <BinaryFile>[];
  for (final page in pages) {
    final type = sniffImageType(page.bytes)!;
    final name = page.name.split('/').last;
    images.add(
      BinaryFile(content: page.bytes, name: name, type: type.fileExtension, path: page.name),
    );
  }

  final cover = images.first;
  final metadata = _metadataFor(comicInfo, format);
  final coverType = sniffImageType(cover.content)!;
  final size = imageSize(cover.content);
  final coverMetadata = metadata.copyWith(
    cover: BookCover(
      bytes: cover.content,
      type: coverType,
      width: size?.width,
      height: size?.height,
    ),
  );

  return ComicBook(cover: cover, metadata: coverMetadata, pages: images, format: format);
}

BookMetadata _metadataFor(final ComicInfo? comicInfo, final BookFormat format) {
  return comicInfo?.metadata.copyWith(format: format) ?? BookMetadata(format: format);
}
