import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/src/features/fb2/entities/fb2_book.dart';
import 'package:e_livre/src/features/fb2/exceptions/fb2_exception.dart';
import 'package:e_livre/src/features/fb2/utils/fb2_to_html.dart';
import 'package:e_livre/src/foundation/entities/book/files.dart';
import 'package:e_livre/src/foundation/entities/book_cover.dart';
import 'package:e_livre/src/foundation/entities/book_format.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';
import 'package:e_livre/src/foundation/entities/file/binary_file.dart';
import 'package:e_livre/src/foundation/entities/file/text_file.dart';
import 'package:e_livre/src/foundation/utils/image_size.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';
import 'package:e_livre/src/foundation/utils/metadata_utils.dart';
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
  final converted = convertBodies(bodies, metadata.title ?? '', _extensionsOf(binaries));

  final htmlFiles = <TextFile>[];
  final images = <BinaryFile>[];
  for (final entry in converted.files.entries) {
    htmlFiles.add(TextFile(name: entry.key, type: 'html', path: entry.key, content: entry.value));
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
  // Fast path: all metadata lives in the leading <description>
  // element and the cover in a single <binary>; parse only those
  // slices instead of building the DOM for the whole document (and
  // base64-decoding every image).
  final typed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final sliced = _readSlicedMetadata(typed);
  if (sliced != null) {
    return sliced;
  }
  final document = _parseXml(bytes);
  return _mapMetadata(document.rootElement, _collectBinaries(document.rootElement));
}

/// Metadata read over the `<description>` slice, or `null` when the
/// document does not match the expected shape (caller falls back to
/// the full parse).
BookMetadata? _readSlicedMetadata(final Uint8List bytes) {
  final description = _sliceElement(bytes, 0, _descriptionOpen, _descriptionClose);
  if (description == null) {
    return null;
  }
  try {
    final wrapper = XmlDocument.parse(
      '<m>${convert.utf8.decode(description.$1, allowMalformed: true)}</m>',
    );
    final root = wrapper.rootElement;
    final coverId = _coverId(root);
    final binaries = <String, BinaryFile>{};
    if (coverId != null) {
      final binary = _sliceCoverBinary(bytes, coverId);
      if (binary != null) {
        binaries[coverId] = binary;
      }
    }
    return _mapMetadata(root, binaries);
  } on Exception {
    // Malformed slice (CDATA tricks, broken markup, ...): the full
    // parse handles the document the honest way.
    return null;
  }
}

/// Returns `(element bytes, end offset)` of the first element whose
/// open tag starts with [open] at/after [from], or `null`.
(Uint8List, int)? _sliceElement(
  final Uint8List bytes,
  final int from,
  final List<int> open,
  final List<int> close,
) {
  final start = _indexOfAscii(bytes, from, open);
  if (start == -1) {
    return null;
  }
  final end = _indexOfAscii(bytes, start + open.length, close);
  if (end == -1) {
    return null;
  }
  return (Uint8List.sublistView(bytes, start, end + close.length), end + close.length);
}

/// Finds the `<binary id="[coverId]">` element and decodes its image.
BinaryFile? _sliceCoverBinary(final Uint8List bytes, final String coverId) {
  var from = 0;
  while (true) {
    final open = _indexOfAscii(bytes, from, _binaryOpen);
    if (open == -1) {
      return null;
    }
    final tagEnd = _indexOfByte(bytes, open, _greaterThan);
    if (tagEnd == -1) {
      return null;
    }
    final tag = convert.utf8.decode(
      Uint8List.sublistView(bytes, open, tagEnd + 1),
      allowMalformed: true,
    );
    if (_attributeValue(tag, 'id') == coverId) {
      final close = _indexOfAscii(bytes, tagEnd, _binaryClose);
      if (close == -1) {
        return null;
      }
      final text = convert.utf8.decode(
        Uint8List.sublistView(bytes, tagEnd + 1, close),
        allowMalformed: true,
      );
      return _decodeBinary(coverId, _attributeValue(tag, 'content-type') ?? 'image/jpeg', text);
    }
    from = tagEnd;
  }
}

/// Extracts a plain attribute value (`name="value"`, single or double
/// quotes) out of a decoded open tag.
String? _attributeValue(final String tag, final String name) {
  var at = tag.indexOf(name);
  while (at != -1) {
    final before = at == 0 ? ' ' : tag[at - 1];
    final separated = before == ' ' || before == '\t' || before == '\n' || before == '\r';
    if (separated) {
      var i = at + name.length;
      while (i < tag.length &&
          (tag[i] == ' ' || tag[i] == '\t' || tag[i] == '\n' || tag[i] == '\r')) {
        i++;
      }
      if (i < tag.length && tag[i] == '=') {
        i++;
        while (i < tag.length &&
            (tag[i] == ' ' || tag[i] == '\t' || tag[i] == '\n' || tag[i] == '\r')) {
          i++;
        }
        if (i < tag.length && (tag[i] == '"' || tag[i] == "'")) {
          final quote = tag[i];
          final end = tag.indexOf(quote, i + 1);
          if (end != -1) {
            return tag.substring(i + 1, end);
          }
        }
      }
    }
    at = tag.indexOf(name, at + 1);
  }
  return null;
}

const List<int> _descriptionOpen = <int>[
  0x3C,
  0x64,
  0x65,
  0x73,
  0x63,
  0x72,
  0x69,
  0x70,
  0x74,
  0x69,
  0x6F,
  0x6E, // <description
];
const List<int> _descriptionClose = <int>[
  0x3C,
  0x2F,
  0x64,
  0x65,
  0x73,
  0x63,
  0x72,
  0x69,
  0x70,
  0x74,
  0x69,
  0x6F,
  0x6E,
  0x3E, // </description>
];
const List<int> _binaryOpen = <int>[0x3C, 0x62, 0x69, 0x6E, 0x61, 0x72, 0x79]; // <binary
const List<int> _binaryClose = <int>[
  0x3C, 0x2F, 0x62, 0x69, 0x6E, 0x61, 0x72, 0x79, 0x3E, // </binary>
];
const int _greaterThan = 0x3E;

int _indexOfAscii(final Uint8List bytes, final int from, final List<int> pattern) {
  final first = pattern[0];
  for (var i = from; i + pattern.length <= bytes.length; i++) {
    if (bytes[i] != first) {
      continue;
    }
    var matched = true;
    for (var j = 1; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return i;
    }
  }
  return -1;
}

int _indexOfByte(final Uint8List bytes, final int from, final int byte) {
  for (var i = from; i < bytes.length; i++) {
    if (bytes[i] == byte) {
      return i;
    }
  }
  return -1;
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
    final binary = _decodeBinary(
      id,
      element.getAttribute('content-type') ?? 'image/jpeg',
      element.innerText,
    );
    if (binary != null) {
      binaries[id] = binary;
    }
  }
  return binaries;
}

BinaryFile? _decodeBinary(final String id, final String contentType, final String base64Text) {
  Uint8List data;
  try {
    data = Uint8List.fromList(convert.base64.decode(base64Text.replaceAll(_whitespacePattern, '')));
  } on FormatException {
    return null;
  }
  final sniffed = sniffImageType(data);
  final extension = sniffed?.fileExtension ?? _extensionFromMime(contentType);
  final fileName = _binaryFileName(id, extension);
  return BinaryFile(content: data, name: fileName, type: extension, path: fileName);
}

final RegExp _whitespacePattern = RegExp(r'\s');

Map<String, String> _extensionsOf(final Map<String, BinaryFile> binaries) {
  return {for (final entry in binaries.entries) entry.key: entry.value.name};
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
        final href =
            image.getAttribute('href', namespace: 'http://www.w3.org/1999/xlink') ??
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

BookMetadata _mapMetadata(final XmlElement root, final Map<String, BinaryFile> binaries) {
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

  final title = first('title-info', 'book-title')?.innerText.trim() ?? '';

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
  final description = annotation
      ?.findAllElements('p')
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
  final keywords = first('title-info', 'keywords')?.innerText.trim() ?? '';
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

  var publishedAt = _parseFb2Date(first('title-info', 'date')?.innerText.trim());
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
  final middle = author.findElements('middle-name').firstOrNull?.innerText.trim();
  final last = author.findElements('last-name').firstOrNull?.innerText.trim();
  final nickname = author.findElements('nickname').firstOrNull?.innerText.trim();

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
  final match = RegExp(r'^(\d{4})(?:[-/.](\d{1,2}))?(?:[-/.](\d{1,2}))?').firstMatch(trimmed);
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
