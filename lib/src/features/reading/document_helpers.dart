import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/image_size.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';

/// Escapes untrusted document text before placing it in generated XHTML.
String escapeHtml(final String value) => const convert.HtmlEscape().convert(value);

/// Decodes a text document using the BOM and common Unicode signatures.
///
/// The parser is deliberately conservative: UTF-8 is the default and
/// malformed sequences are replaced rather than making a readable book
/// disappear because of one bad byte.
String decodeDocumentText(final List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (_startsWith(data, const [0xff, 0xfe, 0x00, 0x00]) ||
      _startsWith(data, const [0x00, 0x00, 0xfe, 0xff])) {
    throw const FormatException('UTF-32 document resources are not supported.');
  }
  if (_startsWith(data, const [0xff, 0xfe])) return _decodeUtf16(data, 2, true);
  if (_startsWith(data, const [0xfe, 0xff])) return _decodeUtf16(data, 2, false);
  if (_startsWith(data, const [0x3c, 0x00, 0x3f, 0x00]) ||
      _startsWith(data, const [0x3c, 0x00, 0x68, 0x00])) {
    return _decodeUtf16(data, 0, true);
  }
  if (_startsWith(data, const [0x00, 0x3c, 0x00, 0x3f]) ||
      _startsWith(data, const [0x00, 0x3c, 0x00, 0x68])) {
    return _decodeUtf16(data, 0, false);
  }

  final offset = _startsWith(data, const [0xef, 0xbb, 0xbf]) ? 3 : 0;

  return convert.utf8.decode(data.sublist(offset), allowMalformed: true);
}

/// Builds a common metadata value from the conventional HTML head fields.
BookMetadata htmlMetadata(
  final String source,
  final BookFormat format, {
  final String? fallbackTitle,
}) {
  final document = html_parser.parse(source);
  final title = _firstNonEmpty(<String?>[
    document.querySelector('title')?.text,
    document.querySelector('meta[property="og:title"]')?.attributes['content'],
    fallbackTitle,
  ]);
  final author = _firstNonEmpty(<String?>[
    document.querySelector('meta[name="author"]')?.attributes['content'],
    document.querySelector('meta[name="creator"]')?.attributes['content'],
    document.querySelector('meta[property="author"]')?.attributes['content'],
  ]);
  final language = _firstNonEmpty(<String?>[
    document.querySelector('html')?.attributes['lang'],
    document.querySelector('meta[http-equiv="content-language"]')?.attributes['content'],
    document.querySelector('meta[name="language"]')?.attributes['content'],
  ]);
  final description = _firstNonEmpty(<String?>[
    document.querySelector('meta[name="description"]')?.attributes['content'],
    document.querySelector('meta[property="og:description"]')?.attributes['content'],
  ]);

  return BookMetadata(
    format: format,
    title: title,
    authors: author == null ? const <String>[] : <String>[author],
    languages: language == null ? const <String>[] : <String>[language],
    description: description,
  );
}

/// Reads the common Calibre/OPF metadata fields without requiring a complete
/// EPUB manifest. TXTZ and HTMLZ use this as a sidecar manifest reader.
BookMetadata opfMetadata(
  final List<int> bytes,
  final BookFormat format, {
  final String? fallbackTitle,
}) {
  final document = XmlDocument.parse(decodeDocumentText(bytes));
  final elements = document.descendants.whereType<XmlElement>().toList();
  String? value(final String local) {
    for (final element in elements) {
      if (element.name.local == local) {
        final text = element.innerText.trim();
        if (text.isNotEmpty) return text;
      }
    }

    return null;
  }

  final metaValues = <String, String>{};
  for (final element in elements.where((final item) => item.name.local == 'meta')) {
    final name = (element.getAttribute('name') ?? element.getAttribute('property') ?? '').trim();
    final content = (element.getAttribute('content') ?? element.innerText).trim();
    if (name.isNotEmpty && content.isNotEmpty) metaValues[name.toLowerCase()] = content;
  }
  final identifierElements = elements.where((final element) => element.name.local == 'identifier');
  final identifiers = <String, String>{};
  var identifierIndex = 0;
  for (final element in identifierElements) {
    final content = element.innerText.trim();
    if (content.isEmpty) continue;
    final scheme = element.getAttribute('scheme') ?? element.getAttribute('opf:scheme');
    identifiers[scheme?.toLowerCase() ?? 'identifier-${identifierIndex++}'] = content;
  }
  final date = DateTime.tryParse(metaValues['calibre:timestamp'] ?? value('date') ?? '');

  return BookMetadata(
    format: format,
    title: value('title') ?? metaValues['title'] ?? fallbackTitle,
    titleSort: metaValues['calibre:title_sort'],
    authorSort: metaValues['calibre:author_sort'],
    bookProducer: metaValues['calibre:book_producer'],
    authors: [
      for (final element in elements.where((final item) => item.name.local == 'creator'))
        if (element.innerText.trim().isNotEmpty) element.innerText.trim(),
    ],
    languages: [
      for (final element in elements.where((final item) => item.name.local == 'language'))
        if (element.innerText.trim().isNotEmpty) element.innerText.trim(),
    ],
    publisher: value('publisher'),
    description: value('description'),
    rights: value('rights'),
    subjects: [
      for (final element in elements.where((final item) => item.name.local == 'subject'))
        if (element.innerText.trim().isNotEmpty) element.innerText.trim(),
    ],
    identifiers: identifiers,
    publishedAt: date,
    series: metaValues['calibre:series'],
    seriesIndex: double.tryParse(metaValues['calibre:series_index'] ?? ''),
    isbn: _isbnOf(identifiers.values),
  );
}

/// Creates heading navigation from an HTML document, preserving nested
/// heading levels through [NavPoint.subNavPoints].
Navigation htmlNavigation(final String source, {final String title = ''}) {
  final document = html_parser.parse(source);
  final headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
  if (headings.isEmpty) return Navigation(title: title, navPoints: const <NavPoint>[]);

  final roots = <NavPoint>[];
  final stack = <(int, NavPoint)>[];
  var order = 0;
  for (final heading in headings) {
    final label = heading.text.trim();
    if (label.isEmpty) continue;
    final level = int.tryParse(heading.localName?.substring(1) ?? '') ?? 1;
    final id = heading.id.isEmpty ? 'heading-${order + 1}' : heading.id;
    final point = NavPoint(
      classAttribute: heading.localName ?? 'h$level',
      id: id,
      playOrder: '${order + 1}',
      label: label,
      content: '#$id',
      subNavPoints: <NavPoint>[],
    );
    order++;
    while (stack.isNotEmpty && stack.last.$1 >= level) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(point);
    } else {
      stack.last.$2.subNavPoints.add(point);
    }
    stack.add((level, point));
  }

  return Navigation(title: title, navPoints: roots);
}

/// Extracts a cover-like image from a list of image files.
BinaryFile? firstImageCover(final List<BinaryFile> images) {
  for (final image in images) {
    if (sniffImageType(image.content) != null) return image;
  }

  return null;
}

/// Converts an image file into the format-agnostic cover value.
BookCover? coverFromBinary(final BinaryFile? image) {
  if (image == null) return null;
  final type = sniffImageType(image.content);
  if (type == null) return null;
  final size = imageSize(image.content);

  return BookCover(bytes: image.content, type: type, width: size?.width, height: size?.height);
}

/// Creates a typed binary entry while keeping the archive-relative path.
BinaryFile binaryFile(final String path, final List<int> bytes) {
  final name = path.split('/').last;
  final type = name.contains('.') ? name.split('.').last.toLowerCase() : '';

  return BinaryFile(
    content: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    name: name,
    type: type,
    path: path,
  );
}

/// Creates a typed text entry while keeping the archive-relative path.
TextFile textFile(final String path, final String content, {final String? type}) {
  final name = path.split('/').last;

  return TextFile(
    content: content,
    name: name,
    type: type ?? (name.contains('.') ? name.split('.').last.toLowerCase() : ''),
    path: path,
  );
}

/// Builds the archive inventory used by the common book model.
List<ArchiveEntry> archiveInventory(final Archive archive) => <ArchiveEntry>[
  for (final entry in archive.files)
    if (entry.isFile) ArchiveEntry(path: entry.name, size: entry.size),
];

/// Reads a ZIP entry's content without exposing the package's mutable list.
Uint8List zipBytes(final ArchiveFile entry) {
  final content = entry.content;

  return content is Uint8List
      ? Uint8List.sublistView(content)
      : Uint8List.fromList(content as List<int>);
}

String? _firstNonEmpty(final Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final value = candidate?.trim();
    if (value != null && value.isNotEmpty) return value;
  }

  return null;
}

String _decodeUtf16(final Uint8List data, final int offset, final bool littleEndian) {
  final length = data.length - offset;
  if (length.isOdd) throw const FormatException('Truncated UTF-16 document resource.');
  final units = <int>[];
  for (var index = offset; index < data.length; index += 2) {
    final first = data[index];
    final second = data[index + 1];
    units.add(littleEndian ? first | second << 8 : first << 8 | second);
  }

  return String.fromCharCodes(units);
}

bool _startsWith(final Uint8List data, final List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (data[index] != prefix[index]) return false;
  }

  return true;
}

String? _isbnOf(final Iterable<String> values) {
  for (final value in values) {
    final compact = value.replaceAll(RegExp(r'[-\s]'), '').toUpperCase();
    if (RegExp(r'^\d{9}[\dX]$').hasMatch(compact) || RegExp(r'^97[89]\d{10}$').hasMatch(compact)) {
      return compact;
    }
  }

  return null;
}
