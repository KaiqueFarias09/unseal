import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:xml/xml.dart';

import '../../../foundation/metadata/book_metadata_operations.dart';

/// Partial metadata extracted from an embedded `ComicInfo.xml`
/// (the de-facto ComicRack schema).
class ComicInfo {
  /// Creates parsed metadata from a ComicInfo document.
  const ComicInfo({required this.metadata});

  /// The parsed metadata (`format` is refined by the caller).
  final BookMetadata metadata;

  /// Parses the [xml] document. Returns `null` when the root element
  /// is not a `ComicInfo` document.
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
