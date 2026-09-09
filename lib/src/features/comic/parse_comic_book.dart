import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import 'archive/rar_reader.dart';
import 'entities/entities.dart';
import 'exceptions/exceptions.dart';
import 'metadata/comic_info.dart';

/// A comic page candidate extracted from an archive.
class _Page {
  const _Page(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// Parses a comic book (CBZ zip or CBR rar) from raw [bytes].
///
/// Pages at a uniform directory depth are ordered naturally by their full
/// archive path. When an archive mixes directory depths, the page basename is
/// the primary ordering key and the full archive path is the deterministic
/// tie-breaker. This keeps mixed-depth archives in the expected reader order.
ComicBook parseComicBook(final Uint8List bytes) {
  final (pages, comicInfo) = _readPages(bytes);

  return _build(pages, comicInfo, _cbz(bytes) ? BookFormat.cbz : BookFormat.cbr);
}

/// Reads only the metadata of a comic book from [bytes].
BookMetadata readComicMetadata(final Uint8List bytes) {
  final (_, comicInfo) = _readPages(bytes);
  final format = _cbz(bytes) ? BookFormat.cbz : BookFormat.cbr;
  if (comicInfo == null) return BookMetadata(format: format);

  return BookMetadata(
    format: format,
    title: comicInfo.metadata.title,
    authors: comicInfo.metadata.authors,
    languages: comicInfo.metadata.languages,
    publisher: comicInfo.metadata.publisher,
    description: comicInfo.metadata.description,
    subjects: comicInfo.metadata.subjects,
    series: comicInfo.metadata.series,
    seriesIndex: comicInfo.metadata.seriesIndex,
  );
}

bool _cbz(final Uint8List bytes) => bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;

(List<_Page>, ComicInfo?) _readPages(final Uint8List bytes) {
  final pages = <_Page>[];
  ComicInfo? comicInfo;

  if (_cbz(bytes)) {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive.files) {
      if (!entry.isFile) {
        continue;
      }

      final content = entry.content;
      final data = content is Uint8List
          ? Uint8List.sublistView(content)
          : Uint8List.fromList(content as List<int>);
      if (entry.name.toLowerCase() == 'comicinfo.xml') {
        comicInfo = ComicInfo.parse(convert.utf8.decode(data, allowMalformed: true));
        continue;
      }

      if (sniffImageType(data) != null) {
        pages.add(_Page(entry.name, data));
      }
    }
  } else {
    for (final entry in readRarEntries(bytes)) {
      if (entry.isDirectory) {
        continue;
      }
      if (!entry.isStored && entry.data.isEmpty) {
        throw ComicException(
          'RAR entry "${entry.name}" is compressed; only stored (uncompressed) '
          'and ordinary RAR 2.9/3.x CBR archives are supported.',
        );
      }
      if (entry.name.toLowerCase() == 'comicinfo.xml') {
        comicInfo = ComicInfo.parse(convert.utf8.decode(entry.data, allowMalformed: true));
        continue;
      }

      if (sniffImageType(entry.data) != null) {
        pages.add(_Page(entry.name, entry.data));
      }
    }
  }
  if (pages.isEmpty) throw const ComicException('No image pages found in the comic archive.');

  _sortPages(pages);

  return (pages, comicInfo);
}

void _sortPages(final List<_Page> pages) {
  final depths = pages.map((final page) => _directoryDepth(page.name)).toSet();
  if (depths.length == 1) {
    pages.sort((final a, final b) => compareNatural(a.name, b.name));
    return;
  }

  pages.sort((final a, final b) {
    final basenameOrder = compareNatural(_archiveBasename(a.name), _archiveBasename(b.name));
    if (basenameOrder != 0) return basenameOrder;

    return compareNatural(a.name, b.name);
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

  var metadata = comicInfo?.metadata ?? BookMetadata(format: format);

  if (comicInfo != null) metadata = metadata.copyWith(format: format);
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

/// Compares strings with embedded numbers by their numeric value so
/// `page2` sorts before `page10`.
int compareNatural(final String a, final String b) {
  var ia = 0;
  var ib = 0;
  while (ia < a.length && ib < b.length) {
    final ca = a.codeUnitAt(ia);
    final cb = b.codeUnitAt(ib);
    final da = ca ^ 0x30;
    final db = cb ^ 0x30;
    if (da <= 9 && db <= 9) {
      var na = 0;
      var nb = 0;
      while (ia < a.length && (a.codeUnitAt(ia) ^ 0x30) <= 9) {
        na = na * 10 + (a.codeUnitAt(ia) ^ 0x30);
        ia++;
      }
      while (ib < b.length && (b.codeUnitAt(ib) ^ 0x30) <= 9) {
        nb = nb * 10 + (b.codeUnitAt(ib) ^ 0x30);
        ib++;
      }
      if (na != nb) return na.compareTo(nb);

      continue;
    }
    if (ca != cb) return ca.compareTo(cb);

    ia++;
    ib++;
  }

  return (a.length - ia).compareTo(b.length - ib);
}
