import 'dart:convert' as convert;

import 'package:xml/xml.dart';

import '../../../foundation/entities/entities.dart';
import '../header/pdf_document.dart';
import '../header/pdf_object.dart';

/// Reads PDF metadata into the format-agnostic [BookMetadata].
///
/// Behaviorally mirrors Calibre's `src/calibre/ebooks/metadata/pdf.py`
/// (GPLv3; re-expressed, not translated): the Info dictionary is the
/// primary source — `/Title`, `/Author`, `/Creator` as producer,
/// `/Subject` + `/Keywords` as tags with the ISBN lifted out of the
/// keywords, `/CreationDate` as the publication date — and the XMP
/// packet (`/Root /Metadata`) fills the fields the Info dictionary
/// left empty.
class PdfMetadataReader {
  const PdfMetadataReader._();

  /// Reads [document]'s metadata.
  static BookMetadata read(final PdfDocument document) {
    final info = document.resolve(document.trailer['Info']);
    final dictionary = info is PdfDictionary ? info : null;

    final title = _textOf(dictionary?['Title']);
    final authorText = _textOf(dictionary?['Author']);
    final producer = _textOf(dictionary?['Creator']);
    final creationDate = _dateOf(dictionary?['CreationDate']);

    final keywords = _textOf(dictionary?['Keywords']);
    final subject = _textOf(dictionary?['Subject']);
    final isbnMatch = _isbnMatch(keywords);
    final isbn = _normalizedIsbn(isbnMatch);
    final subjects = <String>[
      if (subject != null && subject.isNotEmpty) subject,
      ..._splitKeywords(_stripIsbn(keywords, isbnMatch)),
    ].where((final tag) => tag.isNotEmpty).toList();

    final metadata = BookMetadata(
      format: BookFormat.pdf,
      title: title,
      authors: _splitAuthors(authorText),
      bookProducer: producer,
      subjects: subjects,
      isbn: isbn,
      publishedAt: creationDate,
    );

    return _consolidateWithXmp(document, metadata);
  }

  /// Decodes a PDF text string: a UTF-16BE BOM selects UTF-16,
  /// anything else reads as PDFDocEncoding — which this reader
  /// approximates byte-for-byte the way Latin-1 does (the two agree
  /// outside a handful of rare high slots).
  static String? _textOf(final PdfObject? entry) {
    if (entry is! PdfString) return null;
    final bytes = entry.bytes;
    if (bytes.isEmpty) return null;
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return String.fromCharCodes(<int>[
        for (var i = 2; i + 1 < bytes.length; i += 2) bytes[i] * 256 + bytes[i + 1],
      ]);
    }

    return String.fromCharCodes(bytes);
  }

  /// Splits an author line on `&` the way Calibre's
  /// `string_to_authors` does; a line without one stays whole (the
  /// comma form is ambiguous against `Last, First` lists).
  static List<String> _splitAuthors(final String? text) {
    if (text == null || text.isEmpty) return const <String>[];

    return text
        .split('&')
        .map((final name) => name.trim())
        .where((final name) => name.isNotEmpty)
        .toList();
  }

  static List<String> _splitKeywords(final String? keywords) {
    if (keywords == null || keywords.isEmpty) return const <String>[];

    return keywords
        .split(',')
        .map((final tag) => tag.trim())
        .where((final tag) => tag.isNotEmpty)
        .toList();
  }

  /// The Calibre `check_isbn` behavior: find an ISBN token, validate
  /// its 10- or 13-digit checksum, and drop it from the tags.
  static RegExpMatch? _isbnMatch(final String? keywords) {
    if (keywords == null) return null;
    final matcher = RegExp(
      r'(?:isbn)[:\s]*([0-9Xx][0-9Xx\s\-]{7,15}[0-9Xx])',
      caseSensitive: false,
    );
    for (final match in matcher.allMatches(keywords)) {
      final candidate = match.group(1)!.replaceAll(RegExp(r'[\s\-]'), '');
      if (_isValidIsbn(candidate)) return match;
    }

    return null;
  }

  static String? _normalizedIsbn(final RegExpMatch? match) {
    final candidate = match?.group(1);
    if (candidate == null) return null;

    return candidate.replaceAll(RegExp(r'[\s\-]'), '').toUpperCase();
  }

  static String? _stripIsbn(final String? keywords, final RegExpMatch? match) {
    if (keywords == null || match == null) return keywords;
    final stripped = keywords.replaceRange(match.start, match.end, '');

    return stripped.replaceAll(RegExp(r',\s*,'), ',').replaceAll(RegExp(r'[,\s]+$'), '');
  }

  static bool _isValidIsbn(final String candidate) {
    if (candidate.length == 10) {
      var sum = 0;
      for (var i = 0; i < 10; i++) {
        final char = candidate.codeUnitAt(i);
        final value = char == 0x58 || char == 0x78 ? 10 : char - 0x30;
        if (value < 0 || value > 10) return false;
        sum += value * (10 - i);
      }

      return sum % 11 == 0;
    }
    if (candidate.length == 13) {
      var sum = 0;
      for (var i = 0; i < 13; i++) {
        final value = candidate.codeUnitAt(i) - 0x30;
        if (value < 0 || value > 9) return false;
        sum += value * (i.isEven ? 1 : 3);
      }

      return sum % 10 == 0;
    }

    return false;
  }

  /// Parses the PDF date `D:YYYYMMDDHHmmSS…` with its `Z` /
  /// `±HH'mm'` tail (PDF 32000-1:2008 §7.9.4).
  static DateTime? _dateOf(final PdfObject? entry) {
    final text = _textOf(entry);
    if (text == null) return null;
    final match = RegExp(
      r"^(?:D:)?(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?"
      r"(?:([+\-Zz])(\d{2})?'?(\d{2})?'?)?",
    ).firstMatch(text);
    if (match == null) return null;

    final year = int.parse(match.group(1)!);
    final month = int.tryParse(match.group(2) ?? '') ?? 1;
    final day = int.tryParse(match.group(3) ?? '') ?? 1;
    final hour = int.tryParse(match.group(4) ?? '') ?? 0;
    final minute = int.tryParse(match.group(5) ?? '') ?? 0;
    final second = int.tryParse(match.group(6) ?? '') ?? 0;
    var iso =
        '${_pad(year, 4)}-${_pad(month)}-${_pad(day)}'
        'T${_pad(hour)}:${_pad(minute)}:${_pad(second)}';
    final zone = match.group(7);
    if (zone == null) {
      iso = '${iso}Z';
    } else if (zone.toUpperCase() == 'Z') {
      iso = '${iso}Z';
    } else {
      final offsetHours = int.tryParse(match.group(8) ?? '0') ?? 0;
      final offsetMinutes = int.tryParse(match.group(9) ?? '0') ?? 0;
      iso = '$iso$zone${_pad(offsetHours)}:${_pad(offsetMinutes)}';
    }

    return DateTime.tryParse(iso);
  }

  static String _pad(final int value, [final int width = 2]) =>
      value.toString().padLeft(width, '0');

  /// XMP consolidation, after Calibre's `consolidate_metadata`: the
  /// Dublin Core packet only fills fields the Info dictionary left
  /// empty — Info wins because it is what editing tools keep current.
  static BookMetadata _consolidateWithXmp(final PdfDocument document, final BookMetadata info) {
    final stream = document.resolve(document.catalog?['Metadata']);
    if (stream is! PdfStream) return info;

    XmlDocument xml;
    try {
      final text = convert.utf8.decode(document.decodeStream(stream), allowMalformed: true);
      xml = XmlDocument.parse(text);
    } on FormatException {
      return info;
    } on XmlException {
      return info;
    } on Exception {
      return info;
    }

    final title = _xmpValue(xml, 'title') ?? info.title;
    final authors = _xmpValues(xml, 'creator');
    final identifiers = _xmpValues(xml, 'identifier');

    return info.copyWith(
      title: title,
      authors: authors.isEmpty ? info.authors : authors,
      identifiers: <String, String>{
        ...info.identifiers,
        for (var i = 0; i < identifiers.length; i++) 'xmp:$i': identifiers[i],
      },
    );
  }

  /// The first text of a Dublin Core element: its own text or its
  /// `rdf:li` alternates (e.g. `dc:title/rdf:Alt/rdf:li`).
  static String? _xmpValue(final XmlDocument xml, final String localName) {
    for (final element in xml.descendantElements) {
      if (element.name.local != localName) continue;
      final value = _elementText(element);
      if (value != null && value.isNotEmpty) return value;
    }

    return null;
  }

  static List<String> _xmpValues(final XmlDocument xml, final String localName) {
    final values = <String>[];
    for (final element in xml.descendantElements) {
      if (element.name.local != localName) continue;
      final value = _elementText(element);
      if (value != null && value.isNotEmpty) values.add(value);
    }

    return values;
  }

  static String? _elementText(final XmlElement element) {
    for (final child in element.descendantElements) {
      if (child.name.local == 'li') {
        final text = child.innerText.trim();

        return text.isEmpty ? null : text;
      }
    }
    final own = element.innerText.trim();

    return own.isEmpty ? null : own;
  }
}
