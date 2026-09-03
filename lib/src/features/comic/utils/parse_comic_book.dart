import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/comic/entities/comic_book.dart';
import 'package:e_livre/src/features/comic/exceptions/comic_exception.dart';
import 'package:e_livre/src/features/comic/utils/comic_info.dart';
import 'package:e_livre/src/features/comic/utils/rar_reader.dart';
import 'package:e_livre/src/foundation/entities/book_cover.dart';
import 'package:e_livre/src/foundation/entities/book_format.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';
import 'package:e_livre/src/foundation/entities/file/binary_file.dart';
import 'package:e_livre/src/foundation/utils/image_size.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';

/// A comic page candidate extracted from an archive.
class _Page {
  const _Page(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

/// Parses a comic book (CBZ zip or CBR rar) from raw [bytes].
ComicBook parseComicBook(final Uint8List bytes) {
  final (pages, comicInfo) = _readPages(bytes);
  return _build(
    pages,
    comicInfo,
    _cbz(bytes) ? BookFormat.cbz : BookFormat.cbr,
  );
}

/// Reads only the metadata of a comic book from [bytes].
BookMetadata readComicMetadata(final Uint8List bytes) {
  final (_, comicInfo) = _readPages(bytes);
  final format = _cbz(bytes) ? BookFormat.cbz : BookFormat.cbr;
  if (comicInfo == null) {
    return BookMetadata(format: format);
  }
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

bool _cbz(final Uint8List bytes) =>
    bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;

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
        comicInfo = ComicInfo.parse(
          convert.utf8.decode(data, allowMalformed: true),
        );
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
      if (entry.name.toLowerCase() == 'comicinfo.xml' && entry.isStored) {
        comicInfo = ComicInfo.parse(
          convert.utf8.decode(entry.data, allowMalformed: true),
        );
        continue;
      }
      if (!entry.isStored) {
        throw ComicException(
          'RAR entry "${entry.name}" is compressed; only stored (uncompressed) '
          'CBR archives are supported.',
        );
      }
      if (sniffImageType(entry.data) != null) {
        pages.add(_Page(entry.name, entry.data));
      }
    }
  }

  if (pages.isEmpty) {
    throw const ComicException('No image pages found in the comic archive.');
  }
  pages.sort((final a, final b) => compareNatural(a.name, b.name));
  return (pages, comicInfo);
}

ComicBook _build(
  final List<_Page> pages,
  final ComicInfo? comicInfo,
  final BookFormat format,
) {
  final images = <BinaryFile>[];
  for (final page in pages) {
    final type = sniffImageType(page.bytes)!;
    final name = page.name.split('/').last;
    images.add(
      BinaryFile(
        content: page.bytes,
        name: name,
        type: type.fileExtension,
        path: page.name,
      ),
    );
  }

  final cover = images.first;
  var metadata = comicInfo?.metadata ?? BookMetadata(format: format);
  if (comicInfo != null) {
    metadata = metadata.copyWith(format: format);
  }

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

  return ComicBook(
    cover: cover,
    metadata: coverMetadata,
    pages: images,
    format: format,
  );
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
      if (na != nb) {
        return na.compareTo(nb);
      }
    } else {
      if (ca != cb) {
        return ca.compareTo(cb);
      }
      ia++;
      ib++;
    }
  }
  return (a.length - ia).compareTo(b.length - ib);
}
