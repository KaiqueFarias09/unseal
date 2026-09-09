import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/text/document_encoding.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

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

String? _firstNonEmpty(final Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final value = candidate?.trim();
    if (value != null && value.isNotEmpty) return value;
  }

  return null;
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
