import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/features/core/entities/book/files.dart';
import 'package:e_livre/features/core/entities/book_cover.dart';
import 'package:e_livre/features/core/entities/book_format.dart';
import 'package:e_livre/features/core/entities/book_metadata.dart';
import 'package:e_livre/features/core/entities/file/binary_file.dart';
import 'package:e_livre/features/core/entities/file/text_file.dart';
import 'package:e_livre/features/core/utils/image_size.dart';
import 'package:e_livre/features/core/utils/image_sniffer.dart';
import 'package:e_livre/features/core/utils/metadata_utils.dart';
import 'package:e_livre/features/fb2/entities/fb2_book.dart';
import 'package:e_livre/features/fb2/exceptions/fb2_exception.dart';
import 'package:e_livre/features/fb2/utils/fb2_to_html.dart';
import 'package:xml/xml.dart';

/// Parses an FB2 book from raw [bytes] (plain XML or zipped FB2).
Fb2Book parseFb2Book(final Uint8List bytes) {
  if (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive.files) {
      if (file.isFile && file.name.toLowerCase().endsWith('.fb2')) {
        return parseFb2Archive(file);
      }
    }
    throw const Fb2Exception('No .fb2 document found inside the zip archive.');
  }
  return _parseDocument(bytes);
}

/// Parses an FB2 book from a zip archive entry.
Fb2Book parseFb2Archive(final ArchiveFile entry) {
  return _parseDocument(entry.content as List<int>);
}

/// Reads only the metadata of an FB2 book from [bytes].
BookMetadata readFb2Metadata(final Uint8List bytes) {
  if (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive.files) {
      if (file.isFile && file.name.toLowerCase().endsWith('.fb2')) {
        return _readDocumentMetadata(file.content as List<int>);
      }
    }
    throw const Fb2Exception('No .fb2 document found inside the zip archive.');
  }
  return _readDocumentMetadata(bytes);
}

Fb2Book _parseDocument(final List<int> bytes) {
  final document = _parseXml(bytes);
  final root = document.rootElement;
  if (root.name.local != 'FictionBook') {
    throw const Fb2Exception('Not a FictionBook document.');
  }

  final binaries = _collectBinaries(root);
  final bodies = root.findElements('body').toList();
  if (bodies.isEmpty) {
    throw const Fb2Exception('FB2 document has no body.');
  }

  final metadata = _mapMetadata(root, binaries);
  final converted =
      convertBodies(bodies, metadata.title ?? '', _extensionsOf(binaries));

  final htmlFiles = <TextFile>[];
  final images = <BinaryFile>[];
  for (final entry in converted.files.entries) {
    htmlFiles.add(
      TextFile(
        name: entry.key,
        type: 'html',
        path: entry.key,
        content: entry.value,
      ),
    );
  }
  for (final binary in binaries.values) {
    images.add(binary);
  }

  BinaryFile cover = BinaryFile.empty();
  final coverId = _coverId(root);
  if (coverId != null) {
    final binary = binaries[coverId];
    if (binary != null) {
      cover = binary;
    }
  }

  return Fb2Book(
    navigation: converted.navigation,
    files: Files(
      images: images,
      css: const <TextFile>[],
      html: htmlFiles,
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    cover: cover,
    metadata: metadata,
  );
}

BookMetadata _readDocumentMetadata(final List<int> bytes) {
  final document = _parseXml(bytes);
  return _mapMetadata(document.rootElement, _collectBinaries(document.rootElement));
}

XmlDocument _parseXml(final List<int> bytes) {
  // FB2 files may declare arbitrary encodings; the xml package only
  // accepts UTF-16 when the input is typed — decode as UTF-8 with
  // replacement, the overwhelmingly common case.
  final raw = convert.utf8.decode(bytes, allowMalformed: true);
  final withoutBom = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
  try {
    return XmlDocument.parse(withoutBom);
  } on XmlException catch (error) {
    throw Fb2Exception('Invalid FB2 document: $error');
  }
}

Map<String, BinaryFile> _collectBinaries(final XmlElement root) {
  final binaries = <String, BinaryFile>{};
  for (final element in root.findElements('binary')) {
    final id = element.getAttribute('id');
    if (id == null || id.isEmpty) {
      continue;
    }
    final contentType = element.getAttribute('content-type') ?? 'image/jpeg';
    Uint8List data;
    try {
      final normalized = element.innerText.replaceAll(RegExp(r'\s'), '');
      data = Uint8List.fromList(convert.base64.decode(normalized));
    } on FormatException {
      continue;
    }
    final sniffed = sniffImageType(data);
    final extension = sniffed?.fileExtension ??
        _extensionFromMime(contentType);
    final fileName = _binaryFileName(id, extension);
    binaries[id] = BinaryFile(
      content: data,
      name: fileName,
      type: extension,
      path: fileName,
    );
  }
  return binaries;
}

Map<String, String> _extensionsOf(final Map<String, BinaryFile> binaries) {
  return {
    for (final entry in binaries.entries) entry.key: entry.value.name,
  };
}

String _binaryFileName(final String id, final String extension) =>
    id.contains('.') ? id : '$id.$extension';

String _extensionFromMime(final String mime) {
  switch (mime) {
    case 'image/png':
      return 'png';
    case 'image/gif':
      return 'gif';
    case 'image/bmp':
      return 'bmp';
    case 'image/webp':
      return 'webp';
    default:
      return 'jpg';
  }
}

String? _coverId(final XmlElement root) {
  for (final titleInfo in root.findAllElements('title-info')) {
    for (final coverpage in titleInfo.findElements('coverpage')) {
      for (final image in coverpage.findElements('image')) {
        final href = image.getAttribute('href',
                namespace: 'http://www.w3.org/1999/xlink') ??
            image.getAttribute('l:href') ??
            '';
        if (href.startsWith('#') && href.length > 1) {
          return href.substring(1);
        }
      }
    }
  }
  return null;
}

BookMetadata _mapMetadata(
  final XmlElement root,
  final Map<String, BinaryFile> binaries,
) {
  XmlElement? first(final String parent, final String child) {
    for (final parentElement in root.findAllElements(parent)) {
      for (final childElement in parentElement.findElements(child)) {
        return childElement;
      }
    }
    return null;
  }

  Iterable<XmlElement> all(final String parent, final String child) sync* {
    for (final parentElement in root.findAllElements(parent)) {
      for (final childElement in parentElement.findElements(child)) {
        yield childElement;
      }
    }
  }

  final title =
      first('title-info', 'book-title')?.innerText.trim() ?? '';

  final authors = <String>[];
  for (final author in all('title-info', 'author')) {
    final name = _authorName(author);
    if (name.isNotEmpty) {
      authors.add(name);
    }
  }

  final language = first('title-info', 'lang')?.innerText.trim() ?? '';

  final publisher = first('publish-info', 'publisher')?.innerText.trim();

  final annotation = first('title-info', 'annotation');
  final description = annotation?.findAllElements('p')
          .map((final p) => p.innerText.trim())
          .where((final text) => text.isNotEmpty)
          .join('\n\n');

  final rawIsbn = first('publish-info', 'isbn')?.innerText.trim();
  final isbn = rawIsbn == null || rawIsbn.isEmpty
      ? null
      : rawIsbn.replaceAll(RegExp(r'[-\s]'), '').toUpperCase();

  final subjects = <String>[];
  for (final genre in all('title-info', 'genre')) {
    final value = genre.innerText.trim();
    if (value.isNotEmpty && !subjects.contains(value)) {
      subjects.add(value);
    }
  }
  final keywords =
      first('title-info', 'keywords')?.innerText.trim() ?? '';
  if (keywords.isNotEmpty) {
    for (final keyword in keywords.split(RegExp('[,;]'))) {
      final value = keyword.trim();
      if (value.isNotEmpty && !subjects.contains(value)) {
        subjects.add(value);
      }
    }
  }

  String? series;
  double? seriesIndex;
  for (final sequence in all('title-info', 'sequence')) {
    final name = sequence.getAttribute('name')?.trim();
    if (name != null && name.isNotEmpty) {
      series ??= name;
      seriesIndex ??= parseSeriesIndex(sequence.getAttribute('number'));
      break;
    }
  }

  var publishedAt = _parseFb2Date(
    first('title-info', 'date')?.innerText.trim(),
  );
  publishedAt ??= _parseYear(first('publish-info', 'year')?.innerText.trim());

  final identifiers = <String, String>{};
  if (isbn != null && isbn.isNotEmpty) {
    identifiers['isbn'] = isbn;
  }

  BookCover? cover;
  final coverId = _coverId(root);
  if (coverId != null) {
    final binary = binaries[coverId];
    if (binary != null) {
      final type = sniffImageType(binary.content);
      if (type != null) {
        final size = imageSize(binary.content);
        cover = BookCover(
          bytes: binary.content,
          type: type,
          width: size?.width,
          height: size?.height,
        );
      }
    }
  }

  return BookMetadata(
    format: BookFormat.fb2,
    title: title.isEmpty ? null : title,
    authors: authors,
    languages: [if (language.isNotEmpty) language],
    publisher: publisher == null || publisher.isEmpty ? null : publisher,
    description: description == null || description.isEmpty ? null : description,
    isbn: isbn == null || isbn.isEmpty ? null : isbn,
    subjects: subjects,
    publishedAt: publishedAt,
    series: series,
    seriesIndex: seriesIndex,
    identifiers: identifiers,
    cover: cover,
  );
}

String _authorName(final XmlElement author) {
  final first = author.findElements('first-name').firstOrNull?.innerText.trim();
  final middle =
      author.findElements('middle-name').firstOrNull?.innerText.trim();
  final last = author.findElements('last-name').firstOrNull?.innerText.trim();
  final nickname =
      author.findElements('nickname').firstOrNull?.innerText.trim();

  final parts = <String?>[
    if (first != null && first.isNotEmpty) first,
    if (middle != null && middle.isNotEmpty) middle,
    if (last != null && last.isNotEmpty) last,
  ].whereType<String>();
  final name = parts.join(' ').trim();
  if (name.isNotEmpty) {
    return name;
  }
  return nickname ?? '';
}

DateTime? _parseFb2Date(final String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final trimmed = raw.trim();
  final direct = DateTime.tryParse(trimmed);
  if (direct != null) {
    return direct;
  }
  final match = RegExp(
    r'^(\d{4})(?:[-/.](\d{1,2}))?(?:[-/.](\d{1,2}))?',
  ).firstMatch(trimmed);
  if (match == null) {
    return null;
  }
  return DateTime(
    int.parse(match.group(1)!),
    match.group(2) != null ? int.parse(match.group(2)!) : 1,
    match.group(3) != null ? int.parse(match.group(3)!) : 1,
  );
}

DateTime? _parseYear(final String? raw) {
  if (raw == null) {
    return null;
  }
  final match = RegExp(r'^(\d{4})').firstMatch(raw.trim());
  return match == null ? null : DateTime(int.parse(match.group(1)!));
}
