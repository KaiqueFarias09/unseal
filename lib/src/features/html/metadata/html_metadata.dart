import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/image_size.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';
import 'package:e_livre/src/foundation/utils/xml_encoding.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

/// Metadata values collected before the source format is applied.
///
/// Keeping this as a small intermediate value lets HTML metadata and a
/// top-level HTMLZ `metadata.opf` be merged without pretending that OPF is a
/// separate book format.
final class HtmlMetadataValues {
  /// Creates a metadata value set.
  const HtmlMetadataValues({
    this.title,
    this.titleSort,
    this.authorSort,
    this.bookProducer,
    this.authors,
    this.languages,
    this.publisher,
    this.description,
    this.isbn,
    this.subjects,
    this.publishedAt,
    this.rights,
    this.series,
    this.seriesIndex,
    this.identifiers = const <String, String>{},
    this.coverHref,
  });

  /// The source title.
  final String? title;

  /// The source title sort key.
  final String? titleSort;

  /// The source author sort key.
  final String? authorSort;

  /// The producing application or person.
  final String? bookProducer;

  /// Authors in display order.
  final List<String>? authors;

  /// Language tags in display order.
  final List<String>? languages;

  /// Publisher name.
  final String? publisher;

  /// Description or annotation.
  final String? description;

  /// ISBN, when present.
  final String? isbn;

  /// Subject/tag values.
  final List<String>? subjects;

  /// Publication date.
  final DateTime? publishedAt;

  /// Rights statement.
  final String? rights;

  /// Series name.
  final String? series;

  /// Series position.
  final double? seriesIndex;

  /// Other identifiers keyed by source scheme.
  final Map<String, String> identifiers;

  /// OPF manifest href selected as the cover.
  final String? coverHref;
}

/// Reads metadata from an HTML/HTM/XHTML source.
HtmlMetadataValues metadataValuesFromHtml(final String source) {
  final document = html_parser.parse(source);
  final meta = <String, String>{};

  for (final element in document.querySelectorAll('meta')) {
    final content = element.attributes['content']?.trim();
    if (content == null || content.isEmpty) continue;

    final key =
        (element.attributes['name'] ??
                element.attributes['property'] ??
                element.attributes['http-equiv'])
            ?.trim()
            .toLowerCase();
    if (key == null || key.isEmpty) continue;
    meta.putIfAbsent(key, () => content);
  }

  final title = _firstNonEmpty(<String?>[
    document.querySelector('title')?.text,
    _metaValue(meta, const ['title', 'dc.title', 'dcterms.title', 'og:title']),
  ]);
  final htmlLanguage = document.querySelector('html')?.attributes['lang']?.trim();
  final language = _firstNonEmpty(<String?>[
    htmlLanguage,
    _metaValue(meta, const ['language', 'dc.language', 'dcterms.language', 'content-language']),
  ]);
  final author = _firstNonEmpty(<String?>[
    _metaValue(meta, const [
      'author',
      'authors',
      'creator',
      'dc.creator',
      'dcterms.creator',
      'dc.creator.aut',
      'dcterms.creator.aut',
    ]),
  ]);
  final description = _firstNonEmpty(<String?>[
    _metaValue(meta, const [
      'description',
      'dc.description',
      'dcterms.description',
      'comments',
      'og:description',
    ]),
  ]);
  final isbn = _normalizeIsbn(
    _metaValue(meta, const ['isbn', 'dc.identifier.isbn', 'dcterms.identifier.isbn']),
  );

  return HtmlMetadataValues(
    title: title,
    titleSort: _firstNonEmpty(<String?>[
      _metaValue(meta, const ['title_sort', 'calibre:title_sort', 'dc.title.sort']),
    ]),
    authorSort: _firstNonEmpty(<String?>[
      _metaValue(meta, const ['author_sort', 'calibre:author_sort']),
    ]),
    authors: author == null ? null : _splitAuthors(author),
    languages: language == null ? null : _splitValues(language),
    publisher: _firstNonEmpty(<String?>[
      _metaValue(meta, const ['publisher', 'dc.publisher', 'dcterms.publisher']),
    ]),
    description: description,
    isbn: isbn,
    subjects: _valuesOrNull(
      _firstNonEmpty(<String?>[
        _metaValue(meta, const ['subject', 'dc.subject', 'dcterms.subject', 'tags']),
      ]),
    ),
    publishedAt: _parseDate(
      _metaValue(meta, const ['date', 'pubdate', 'dc.date', 'dc.date.published', 'dcterms.issued']),
    ),
    rights: _firstNonEmpty(<String?>[
      _metaValue(meta, const ['rights', 'dc.rights', 'dcterms.rights']),
    ]),
    series: _firstNonEmpty(<String?>[
      _metaValue(meta, const ['series', 'calibre:series']),
    ]),
    seriesIndex: double.tryParse(
      _metaValue(meta, const ['series_index', 'seriesnumber', 'calibre:series_index']) ?? '',
    ),
  );
}

/// Reads the common OPF metadata used inside HTMLZ archives.
///
/// OPF is intentionally only a metadata/manifest input here. The returned
/// values never change the source format from HTMLZ.
HtmlMetadataValues metadataValuesFromOpf(final List<int> bytes) {
  final document = XmlDocument.parse(decodeXmlText(bytes));
  final metadataElement = document.descendants.whereType<XmlElement>().firstWhere(
    (final element) => element.name.local.toLowerCase() == 'metadata',
    orElse: () => document.rootElement,
  );

  String? value(final String localName) {
    for (final element in metadataElement.children.whereType<XmlElement>()) {
      if (element.name.local.toLowerCase() == localName.toLowerCase()) {
        final text = element.innerText.trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  final creators = <String>[];
  final subjects = <String>[];
  final languages = <String>[];
  final identifiers = <String, String>{};
  String? titleSort;
  String? authorSort;
  String? bookProducer;
  String? series;
  double? seriesIndex;
  String? coverId;

  for (final element in metadataElement.children.whereType<XmlElement>()) {
    final localName = element.name.local.toLowerCase();
    final text = element.innerText.trim();
    if (localName == 'creator' && text.isNotEmpty) {
      creators.add(text);
      authorSort ??= _attributeByLocalName(element, 'file-as');
      continue;
    }
    if (localName == 'subject' && text.isNotEmpty) {
      subjects.add(text);
      continue;
    }
    if (localName == 'language' && text.isNotEmpty) {
      languages.add(text);
      continue;
    }
    if (localName == 'identifier' && text.isNotEmpty) {
      final scheme = _firstNonEmpty(<String?>[
        _attributeByLocalName(element, 'scheme'),
        _attributeByLocalName(element, 'id'),
      ]);
      identifiers[scheme ?? 'identifier-${identifiers.length}'] = text;
      continue;
    }
    if (localName != 'meta') continue;

    final name = _attributeByLocalName(element, 'name')?.toLowerCase();
    final property = _attributeByLocalName(element, 'property')?.toLowerCase();
    final content = _firstNonEmpty(<String?>[_attributeByLocalName(element, 'content'), text]);
    if (content == null) continue;

    switch (name ?? property) {
      case 'cover':
        coverId = content;
      case 'calibre:series':
      case 'series':
        series = content;
      case 'calibre:series_index':
      case 'series_index':
        seriesIndex = double.tryParse(content);
      case 'belongs-to-collection':
        series = content;
      case 'group-position':
        seriesIndex = double.tryParse(content);
      case 'calibre:title_sort':
      case 'title_sort':
        titleSort = content;
      case 'calibre:author_sort':
      case 'author_sort':
        authorSort = content;
      case 'calibre:timestamp':
      case 'calibre:created_by':
        bookProducer = content;
    }
  }

  String? coverHref;
  final manifest = document.descendants.whereType<XmlElement>().where(
    (final element) => element.name.local.toLowerCase() == 'manifest',
  );
  final items = manifest.expand(
    (final element) => element.children.whereType<XmlElement>().where(
      (final child) => child.name.local.toLowerCase() == 'item',
    ),
  );
  final itemList = items.toList(growable: false);
  XmlElement? coverItem;
  if (coverId != null) {
    for (final item in itemList) {
      if (_attributeByLocalName(item, 'id') == coverId) {
        coverItem = item;
        break;
      }
    }
  }
  coverItem ??= itemList.cast<XmlElement?>().firstWhere(
    (final item) => (_attributeByLocalName(item!, 'properties') ?? '')
        .split(RegExp(r'\s+'))
        .any((final property) => property.toLowerCase() == 'cover-image'),
    orElse: () => null,
  );
  coverItem ??= itemList.cast<XmlElement?>().firstWhere(
    (final item) =>
        (_attributeByLocalName(item!, 'id') ?? '').toLowerCase().contains('cover') &&
        (_attributeByLocalName(item, 'media-type') ?? '').toLowerCase().startsWith('image/'),
    orElse: () => null,
  );
  if (coverItem != null) coverHref = _attributeByLocalName(coverItem, 'href');

  final guide = document.descendants.whereType<XmlElement>().where(
    (final element) => element.name.local.toLowerCase() == 'reference',
  );
  for (final reference in guide) {
    if (coverHref != null) break;
    if ((_attributeByLocalName(reference, 'type') ?? '').toLowerCase() == 'cover') {
      coverHref = _attributeByLocalName(reference, 'href');
    }
  }

  return HtmlMetadataValues(
    title: value('title'),
    titleSort: titleSort,
    authorSort: authorSort,
    bookProducer: bookProducer,
    authors: creators.isEmpty ? null : creators,
    languages: languages.isEmpty ? null : languages,
    publisher: value('publisher'),
    description: value('description'),
    isbn: _normalizeIsbn(value('isbn')),
    subjects: subjects.isEmpty ? null : subjects,
    publishedAt: _parseDate(value('date')),
    rights: value('rights'),
    series: series,
    seriesIndex: seriesIndex,
    identifiers: identifiers,
    coverHref: coverHref,
  );
}

/// Merges the values from [overlay] over [base], retaining HTML fallbacks.
HtmlMetadataValues mergeMetadataValues(
  final HtmlMetadataValues base,
  final HtmlMetadataValues overlay,
) {
  return HtmlMetadataValues(
    title: overlay.title ?? base.title,
    titleSort: overlay.titleSort ?? base.titleSort,
    authorSort: overlay.authorSort ?? base.authorSort,
    bookProducer: overlay.bookProducer ?? base.bookProducer,
    authors: overlay.authors ?? base.authors,
    languages: overlay.languages ?? base.languages,
    publisher: overlay.publisher ?? base.publisher,
    description: overlay.description ?? base.description,
    isbn: overlay.isbn ?? base.isbn,
    subjects: overlay.subjects ?? base.subjects,
    publishedAt: overlay.publishedAt ?? base.publishedAt,
    rights: overlay.rights ?? base.rights,
    series: overlay.series ?? base.series,
    seriesIndex: overlay.seriesIndex ?? base.seriesIndex,
    identifiers: <String, String>{...base.identifiers, ...overlay.identifiers},
    coverHref: overlay.coverHref ?? base.coverHref,
  );
}

/// Converts the intermediate values into the library's public metadata.
BookMetadata buildHtmlMetadata(
  final HtmlMetadataValues values,
  final BookFormat format, {
  final BinaryFile? cover,
}) {
  return BookMetadata(
    format: format,
    title: _nonEmptyOrNull(values.title),
    titleSort: _nonEmptyOrNull(values.titleSort),
    authorSort: _nonEmptyOrNull(values.authorSort),
    bookProducer: _nonEmptyOrNull(values.bookProducer),
    authors: values.authors ?? const <String>[],
    languages: values.languages ?? const <String>[],
    publisher: _nonEmptyOrNull(values.publisher),
    description: _nonEmptyOrNull(values.description),
    isbn: values.isbn,
    subjects: values.subjects ?? const <String>[],
    publishedAt: values.publishedAt,
    rights: _nonEmptyOrNull(values.rights),
    series: _nonEmptyOrNull(values.series),
    seriesIndex: values.seriesIndex,
    identifiers: values.identifiers,
    cover: _bookCover(cover),
  );
}

String? _metaValue(final Map<String, String> values, final List<String> keys) {
  for (final key in keys) {
    final value = values[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

String? _firstNonEmpty(final Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

List<String> _splitAuthors(final String value) {
  return value
      .split(RegExp(r'\s*;\s*|\s*\|\s*|\s+\band\b\s+', caseSensitive: false))
      .map((final author) => author.trim())
      .where((final author) => author.isNotEmpty)
      .toList(growable: false);
}

List<String> _splitValues(final String value) {
  return value
      .split(RegExp(r'\s*[,;|]\s*'))
      .map((final item) => item.trim())
      .where((final item) => item.isNotEmpty)
      .toList(growable: false);
}

List<String>? _valuesOrNull(final String? value) {
  if (value == null) return null;
  final values = _splitValues(value);
  return values.isEmpty ? null : values;
}

String? _normalizeIsbn(final String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final compact = trimmed.replaceAll(RegExp(r'[-\s]'), '').toUpperCase();
  final isbn10 = compact.length == 10 && RegExp(r'^\d{9}[\dX]$').hasMatch(compact);
  final isbn13 = compact.length == 13 && RegExp(r'^97[89]\d{10}$').hasMatch(compact);
  return isbn10 || isbn13 ? compact : trimmed;
}

DateTime? _parseDate(final String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final direct = DateTime.tryParse(trimmed);
  if (direct != null) return direct;
  final match = RegExp(r'^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?').firstMatch(trimmed);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.tryParse(match.group(2) ?? '') ?? 1,
    int.tryParse(match.group(3) ?? '') ?? 1,
  );
}

String? _attributeByLocalName(final XmlElement element, final String name) {
  for (final attribute in element.attributes) {
    if (attribute.name.local.toLowerCase() == name.toLowerCase()) return attribute.value.trim();
  }
  return null;
}

String? _nonEmptyOrNull(final String? value) => _firstNonEmpty(<String?>[value]);

BookCover? _bookCover(final BinaryFile? cover) {
  if (cover == null || cover.isEmpty) return null;
  final type = sniffImageType(cover.content);
  if (type == null) return null;
  final size = imageSize(cover.content);
  return BookCover(bytes: cover.content, type: type, width: size?.width, height: size?.height);
}
