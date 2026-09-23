import 'package:xml/xml.dart';

import '../../../foundation/entities/entities.dart';
import '../../../foundation/metadata/series_index.dart';
import '../entities/comic_page_info.dart';

/// Partial metadata extracted from an embedded `ComicInfo.xml` (the de-facto ComicRack schema).
class ComicInfo {
  /// Creates parsed metadata from a ComicInfo document.
  const ComicInfo({
    required this.metadata,
    this.readingDirection = ComicReadingDirection.unspecified,
    this.pageInfo = const <ComicPageInfo>[],
  });

  /// The parsed metadata (`format` is refined by the caller).
  final BookMetadata metadata;

  /// Direction explicitly declared by the `Manga` field.
  final ComicReadingDirection readingDirection;

  /// Valid page declarations, indexed into the naturally ordered image list.
  final List<ComicPageInfo> pageInfo;

  /// Parses the [xml] document. Returns `null` when the root element is not a `ComicInfo` document.
  static ComicInfo? parse(final String xml) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException {
      return null;
    }
    if (document.rootElement.name.local != 'ComicInfo') return null;

    String? value(final String name) {
      final element = _findChild(document.rootElement, name);
      final text = element?.innerText.trim();

      return text == null || text.isEmpty ? null : text;
    }

    final series = value('Series');
    final writers = _splitList(value('Writer'));
    final genres = [..._splitList(value('Genre')), ..._splitList(value('Tags'))];

    return ComicInfo(
      readingDirection: value('Manga') == 'YesAndRightToLeft'
          ? ComicReadingDirection.rightToLeft
          : ComicReadingDirection.unspecified,
      pageInfo: _pageInfoOf(document.rootElement),
      metadata: BookMetadata(
        format: BookFormat.cbz,
        title: value('Title') ?? series,
        authors: writers,
        languages: [if (value('LanguageISO') != null) value('LanguageISO')!],
        publisher: value('Publisher'),
        description: value('Summary'),
        subjects: genres,
        series: series,
        seriesIndex: parseSeriesIndex(value('Number')),
      ),
    );
  }

  static List<ComicPageInfo> _pageInfoOf(final XmlElement root) {
    final pages = _findChild(root, 'Pages');
    if (pages == null) return const <ComicPageInfo>[];

    final result = <ComicPageInfo>[];
    final seen = <int>{};
    for (final element in pages.children.whereType<XmlElement>()) {
      if (element.name.local != 'Page') continue;
      final index = int.tryParse(element.getAttribute('Image') ?? '');
      if (index == null || index < 0 || !seen.add(index)) continue;

      final rawType = element.getAttribute('Type')?.trim();
      final type = rawType == null || rawType.isEmpty ? 'Story' : rawType;
      result.add(
        ComicPageInfo(
          imageIndex: index,
          type: ComicPageType.fromComicInfo(type),
          rawType: type,
          doublePage: switch (element.getAttribute('DoublePage')?.toLowerCase()) {
            'true' || '1' => true,
            _ => false,
          },
          bookmark: _nonEmpty(element.getAttribute('Bookmark')),
          imageSize: _positiveInt(element.getAttribute('ImageSize')),
          imageWidth: _positiveInt(element.getAttribute('ImageWidth')),
          imageHeight: _positiveInt(element.getAttribute('ImageHeight')),
        ),
      );
    }

    return result;
  }

  static String? _nonEmpty(final String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static int? _positiveInt(final String? value) {
    final number = int.tryParse(value ?? '');
    return number != null && number > 0 ? number : null;
  }

  static XmlElement? _findChild(final XmlElement root, final String localName) {
    for (final child in root.children.whereType<XmlElement>()) {
      if (child.name.local == localName) return child;
    }

    return null;
  }

  static List<String> _splitList(final String? raw) {
    if (raw == null) return const <String>[];

    return raw
        .split(RegExp('[,;]'))
        .map((final part) => part.trim())
        .where((final part) => part.isNotEmpty)
        .toList();
  }
}

/// Aligns valid ComicInfo page declarations to the ordered archive images.
List<ComicPageInfo> comicPageInfoFor(final ComicInfo? info, final int pageCount) {
  final result = <ComicPageInfo>[
    for (var index = 0; index < pageCount; index++) ComicPageInfo(imageIndex: index),
  ];
  for (final page in info?.pageInfo ?? const <ComicPageInfo>[]) {
    if (page.imageIndex < pageCount) result[page.imageIndex] = page;
  }

  return result;
}
