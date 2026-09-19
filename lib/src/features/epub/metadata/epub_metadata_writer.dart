import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';
import '../../../foundation/archive/archive_access.dart';

import '../../../foundation/metadata/sort_keys.dart';
import '../../../foundation/metadata/title_sort.dart';
import '../container/epub_root_file.dart';

/// The metadata changes to apply to an EPUB file.
///
/// Every non-null field is written into the OPF; `null` fields are
/// left untouched. An explicit [titleSort]/[authorSort] is stored as-is;
/// when a title or author is set without its sort key, the key is computed
/// from the corresponding display value.
final class EpubMetadataUpdate {
  /// Creates an [EpubMetadataUpdate].
  const EpubMetadataUpdate({
    this.title,
    this.titleSort,
    this.authors,
    this.authorSort,
    this.publisher,
    this.language,
    this.description,
    this.subjects,
    this.rights,
    this.publishedAt,
    this.series,
    this.seriesIndex,
  });

  /// The new title.
  final String? title;

  /// The new title sort key (computed from [title] when both are set
  /// and this is omitted).
  final String? titleSort;

  /// The new author list, in display order.
  final List<String>? authors;

  /// The new author sort key (computed from [authors] when both are
  /// set and this is omitted).
  final String? authorSort;

  /// The new publisher.
  final String? publisher;

  /// The new primary language (ISO code such as `en` or `pt-BR`).
  final String? language;

  /// The new description / summary (HTML allowed, as in the OPF).
  final String? description;

  /// The new subject / genre list, replacing the existing ones.
  final List<String>? subjects;

  /// The new copyright / rights statement.
  final String? rights;

  /// The new publication date.
  final DateTime? publishedAt;

  /// The series name, written to a legacy OPF `meta` value.
  final String? series;

  /// The position inside the series, written to a legacy OPF `meta` value.
  final double? seriesIndex;
}

/// Rewrites the OPF of the EPUB in [bytes] with [update] applied and
/// returns the new EPUB bytes.
///
/// Every other zip entry is preserved verbatim; only the OPF entry is
/// rewritten (so entry order, the uncompressed `mimetype` first entry
/// and all content files survive). Identifiers and the cover image
/// are not touched by this writer.
Uint8List updateEpubMetadata(final Uint8List bytes, final EpubMetadataUpdate update) {
  final archive = decodeBookZip(bytes);
  final rootFilePath = getEpubRootFilePath(archive);
  if (rootFilePath == null) {
    throw const FormatException('EPUB metadata writing error: no root file found.');
  }

  final rootFile = archive.files.firstWhere(
    (final file) => _samePath(file.name, rootFilePath),
    orElse: () => throw const FormatException('EPUB metadata writing error: no root file found.'),
  );
  final document = XmlDocument.parse(convert.utf8.decode(rootFile.content as List<int>));
  final metadataElement = document.rootElement.findElements('metadata').firstOrNull;
  if (metadataElement == null) {
    throw const FormatException('EPUB metadata writing error: no metadata element found.');
  }

  _applyMetadataUpdate(metadataElement, update);

  final updatedXml = convert.utf8.encode(document.toXmlString());
  final updatedEntry = ArchiveFile(rootFilePath, updatedXml.length, updatedXml);

  final out = Archive();
  // EPUB requires the uncompressed `mimetype` entry to come first.
  for (final file in archive.files) {
    if (file.isFile && _samePath(file.name, 'mimetype')) {
      final mimetype = ArchiveFile(file.name, file.size, file.content)
        ..compression = CompressionType.none;
      out.addFile(mimetype);
      break;
    }
  }

  var rootWritten = false;
  for (final file in archive.files) {
    if (!file.isFile || _samePath(file.name, 'mimetype')) continue;
    if (_samePath(file.name, rootFilePath)) {
      out.addFile(updatedEntry);
      rootWritten = true;
      continue;
    }

    out.addFile(ArchiveFile(file.name, file.size, file.content));
  }
  if (!rootWritten) out.addFile(updatedEntry);

  final encoded = ZipEncoder().encode(out);

  return Uint8List.fromList(encoded);
}

bool _samePath(final String a, final String b) {
  return a.replaceAll('\\', '/') == b.replaceAll('\\', '/');
}

void _applyMetadataUpdate(final XmlElement metadata, final EpubMetadataUpdate update) {
  _applyTitleUpdate(metadata, update);
  _applyAuthorUpdate(metadata, update);
  _applyPublicationUpdate(metadata, update);
  _applySeriesUpdate(metadata, update);
}

void _applyTitleUpdate(final XmlElement metadata, final EpubMetadataUpdate update) {
  if (update.title != null) {
    _setDcElement(metadata, 'title', update.title!);
    final sort = update.titleSort ?? computeTitleSortKey(update.title!);
    _setNamedMeta(metadata, 'calibre:title_sort', sort);

    return;
  }
  if (update.titleSort != null) _setNamedMeta(metadata, 'calibre:title_sort', update.titleSort!);
}

void _applyAuthorUpdate(final XmlElement metadata, final EpubMetadataUpdate update) {
  if (update.authors != null) {
    _removeDcElements(metadata, 'creator');
    for (final author in update.authors!) {
      metadata.children.add(
        XmlElement(
          XmlName.qualified('dc:creator'),
          [XmlAttribute(XmlName.qualified('opf:file-as'), authorToAuthorSort(author))],
          [XmlText(author)],
        ),
      );
    }

    final sort = update.authorSort ?? authorsToSortString(update.authors!);
    _setNamedMeta(metadata, 'calibre:author_sort', sort);

    return;
  }
  if (update.authorSort != null) _setNamedMeta(metadata, 'calibre:author_sort', update.authorSort!);
}

void _applyPublicationUpdate(final XmlElement metadata, final EpubMetadataUpdate update) {
  if (update.publisher != null) _setDcElement(metadata, 'publisher', update.publisher!);
  if (update.language != null) _setDcElement(metadata, 'language', update.language!);
  if (update.description != null) _setDcElement(metadata, 'description', update.description!);
  if (update.rights != null) _setDcElement(metadata, 'rights', update.rights!);
  if (update.publishedAt != null) {
    _setDcElement(metadata, 'date', update.publishedAt!.toIso8601String());
  }
  if (update.subjects != null) {
    _removeDcElements(metadata, 'subject');
    for (final subject in update.subjects!) {
      metadata.children.add(
        XmlElement(XmlName.qualified('dc:subject'), const [], [XmlText(subject)]),
      );
    }
  }
}

void _applySeriesUpdate(final XmlElement metadata, final EpubMetadataUpdate update) {
  if (update.series != null) _setNamedMeta(metadata, 'calibre:series', update.series!);
  if (update.seriesIndex != null) {
    _setNamedMeta(metadata, 'calibre:series_index', _formatIndex(update.seriesIndex!));
  }
}

/// Sets the text of the first `dc:[name]` element, creating it when
/// the metadata block does not carry one yet.
void _setDcElement(final XmlElement metadata, final String name, final String value) {
  final existing = metadata.childElements.firstWhereOrNull(
    (final element) => _isDcElement(element, name),
  );
  if (existing != null) {
    existing.children
      ..clear()
      ..add(XmlText(value));

    return;
  }

  metadata.children.add(XmlElement(XmlName.qualified('dc:$name'), const [], [XmlText(value)]));
}

void _removeDcElements(final XmlElement metadata, final String name) {
  metadata.children.removeWhere((final child) => child is XmlElement && _isDcElement(child, name));
}

bool _isDcElement(final XmlElement element, final String name) {
  const dcNamespace = 'http://purl.org/dc/elements/1.1/';

  return element.name.local == name &&
      (element.namespaceUri == dcNamespace || element.name.qualified == 'dc:$name');
}

/// Updates or creates `<meta name="[name]" content="[value]"/>`.
void _setNamedMeta(final XmlElement metadata, final String name, final String value) {
  for (final meta in metadata.findElements('meta')) {
    if (meta.getAttribute('name') == name) {
      meta.setAttribute('content', value);

      return;
    }
  }
  metadata.children.add(
    XmlElement(XmlName.qualified('meta'), [
      XmlAttribute(XmlName.qualified('name'), name),
      XmlAttribute(XmlName.qualified('content'), value),
    ]),
  );
}

/// `2.5` → `2.5`; integral values no greater than `0x7FFFFFFF` omit `.0`.
String _formatIndex(final double index) {
  if (index == index.roundToDouble()) {
    final whole = index.round();
    if (whole <= 0x7FFFFFFF) return '$whole';
  }

  return '$index';
}
