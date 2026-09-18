part of '../parse_fb2_book.dart';

/// Reads metadata from a selected plain FB2 XML [source].
BookMetadata _readFb2SourceMetadata(final _Fb2Source source) {
  // Fast path: all metadata lives in the leading <description>
  // element and the cover in a single <binary>; parse only those
  // slices instead of building the DOM for the whole document (and
  // base64-decoding every image).
  final bytes = source.bytes is Uint8List
      ? source.bytes as Uint8List
      : Uint8List.fromList(source.bytes);
  // Sniff once: the declaration lives at the document start, while
  // both the fast metadata path and the cover slice see only parts.
  final encoding = sniffXmlEncoding(bytes);
  final sliced = _readSlicedMetadata(bytes, encoding);
  if (sliced != null) return sliced;

  final document = source.parseXml();

  return _mapFb2Metadata(document.rootElement, _Fb2Resources.fromRoot(document.rootElement));
}

/// Maps FB2 description and publication fields to the common metadata model.
BookMetadata _mapFb2Metadata(final XmlElement root, final _Fb2Resources resources) {
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
    if (name.isNotEmpty) authors.add(name);
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
    if (value.isNotEmpty && !subjects.contains(value)) subjects.add(value);
  }
  final keywords = first('title-info', 'keywords')?.innerText.trim() ?? '';
  if (keywords.isNotEmpty) {
    for (final keyword in keywords.split(RegExp('[,;]'))) {
      final value = keyword.trim();
      if (value.isNotEmpty && !subjects.contains(value)) subjects.add(value);
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

  final date = first('title-info', 'date');
  var publishedAt = _parseFb2Date(date?.getAttribute('value'));
  publishedAt ??= _parseFb2Date(date?.innerText.trim());
  publishedAt ??= _parseYear(first('publish-info', 'year')?.innerText.trim());

  final identifiers = <String, String>{};
  if (isbn != null && isbn.isNotEmpty) identifiers['isbn'] = isbn;

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
    cover: resources.metadataCover,
  );
}

/// Metadata read over the `<description>` slice, or `null` when the
/// document does not match the expected shape (caller falls back to
/// the full parse).
BookMetadata? _readSlicedMetadata(final Uint8List bytes, final XmlEncoding encoding) {
  final description = _sliceElement(bytes, 0, '<description', '</description>');
  if (description == null) return null;

  try {
    final wrapper = XmlDocument.parse('<m>${decodeXmlTextAs(description.$1, encoding)}</m>');
    final root = wrapper.rootElement;
    final coverId = _fb2CoverId(root);
    final binaries = <String, BinaryFile>{};
    if (coverId != null) {
      final binary = _sliceCoverBinary(bytes, coverId, encoding);
      if (binary != null) binaries[coverId] = binary;
    }

    return _mapFb2Metadata(root, _Fb2Resources.fromBinaries(root, binaries));
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
  final String open,
  final String close,
) {
  final start = _indexOfAscii(bytes, from, open);
  if (start == -1) return null;

  final end = _indexOfAscii(bytes, start + open.length, close);
  if (end == -1) return null;

  return (Uint8List.sublistView(bytes, start, end + close.length), end + close.length);
}

/// Finds the `<binary id="[coverId]">` element and decodes its image.
BinaryFile? _sliceCoverBinary(
  final Uint8List bytes,
  final String coverId,
  final XmlEncoding encoding,
) {
  var from = 0;
  while (true) {
    final open = _indexOfAscii(bytes, from, '<binary');
    if (open == -1) return null;

    final tagEnd = _indexOfByte(bytes, open, 0x3E);
    if (tagEnd == -1) return null;

    final tag = decodeXmlTextAs(Uint8List.sublistView(bytes, open, tagEnd + 1), encoding);
    if (_attributeValue(tag, 'id') == coverId) {
      final close = _indexOfAscii(bytes, tagEnd, '</binary>');
      if (close == -1) return null;

      final text = decodeXmlTextAs(Uint8List.sublistView(bytes, tagEnd + 1, close), encoding);

      return _decodeFb2Binary(coverId, _attributeValue(tag, 'content-type') ?? 'image/jpeg', text);
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
          if (end != -1) return tag.substring(i + 1, end);
        }
      }
    }
    at = tag.indexOf(name, at + 1);
  }

  return null;
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
  if (name.isNotEmpty) return name;

  return nickname ?? '';
}

DateTime? _parseFb2Date(final String? raw) {
  if (raw == null || raw.isEmpty) return null;

  final trimmed = raw.trim();
  final match = RegExp(r'^(\d{4})(?:[-/.](\d{1,2}))?(?:[-/.](\d{1,2}))?').firstMatch(trimmed);
  if (match == null) return null;

  final year = int.parse(match.group(1)!);
  final month = match.group(2) == null ? 1 : int.parse(match.group(2)!);
  final day = match.group(3) == null ? 1 : int.parse(match.group(3)!);
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;

  return DateTime.tryParse(trimmed) ?? date;
}

DateTime? _parseYear(final String? raw) {
  if (raw == null) return null;

  final match = RegExp(r'^(\d{4})').firstMatch(raw.trim());

  return match == null ? null : DateTime(int.parse(match.group(1)!));
}

int _indexOfAscii(final Uint8List bytes, final int from, final String pattern) {
  final first = pattern.codeUnitAt(0);
  for (var i = from; i + pattern.length <= bytes.length; i++) {
    if (bytes[i] != first) continue;

    var isMatched = true;
    for (var j = 1; j < pattern.length; j++) {
      if (bytes[i + j] != pattern.codeUnitAt(j)) {
        isMatched = false;
        break;
      }
    }

    if (isMatched) return i;
  }

  return -1;
}

int _indexOfByte(final Uint8List bytes, final int from, final int byte) {
  for (var i = from; i < bytes.length; i++) {
    if (bytes[i] == byte) return i;
  }

  return -1;
}
