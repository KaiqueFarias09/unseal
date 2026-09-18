part of '../parse_txt_book.dart';

/// Upper bound for one uncompressed TXTZ member. This keeps a malformed
/// archive from forcing the reader to retain an unexpectedly large payload.
const _maxTxtzEntryBytes = 64 * 1024 * 1024;

/// Upper bound for the number of TXTZ members accepted by the adapter.
const _maxTxtzEntries = 10 * 1000;

/// Upper bound for the total uncompressed TXTZ payload retained by the
/// adapter after ZIP decoding.
const _maxTxtzTotalBytes = 256 * 1024 * 1024;

/// One validated file entry from a TXTZ archive.
final class _TxtzArchiveFile {
  /// Creates a TXTZ entry.
  const _TxtzArchiveFile({required this.path, required this.bytes});

  /// Canonical, archive-relative path.
  final String path;

  /// Uncompressed entry bytes.
  final Uint8List bytes;

  /// Lowercase extension without the dot.
  String get extension {
    return _txtzExtension(path);
  }

  /// Basename without its directory.
  String get name => path.substring(path.lastIndexOf('/') + 1);
}

/// Validated TXTZ contents, with text files selected in a deterministic
/// order and `metadata.opf` kept as package metadata rather than content.
final class _TxtzArchiveContents {
  /// Creates validated TXTZ contents.
  const _TxtzArchiveContents({
    required this.files,
    required this.textFiles,
    required this.archiveEntries,
    this.metadata,
    this.metadataPath,
  });

  /// Every physical file entry, including metadata and resources.
  final List<_TxtzArchiveFile> files;

  /// TXT-family entries in natural path order.
  final List<_TxtzArchiveFile> textFiles;

  /// Archive entries exposed by the shared document model.
  final List<ArchiveEntry> archiveEntries;

  /// Parsed metadata hints, when `metadata.opf` is valid.
  final _TxtzMetadata? metadata;

  /// Archive path of the parsed metadata file.
  final String? metadataPath;
}

/// Metadata and conversion hints stored in a TXTZ `metadata.opf` file.
final class _TxtzMetadata {
  /// Creates TXTZ metadata.
  const _TxtzMetadata({required this.metadata, this.coverPath, this.formatting});

  /// Normalized metadata mapped to eLivre's common contract.
  final BookMetadata metadata;

  /// Resolved archive path of the optional cover resource.
  final String? coverPath;

  /// `plain`, `markdown`, or `textile` when declared by the archive.
  final String? formatting;
}

/// Decodes and validates a TXTZ [archive].
_TxtzArchiveContents _readTxtzArchive(final Archive archive) {
  if (archive.files.length > _maxTxtzEntries) {
    throw const InvalidBookException('TXTZ archive contains too many entries.');
  }

  final files = <_TxtzArchiveFile>[];
  final archiveEntries = <ArchiveEntry>[];
  final seenPaths = <String>{};
  var totalBytes = 0;
  for (final entry in archive.files) {
    final path = _validatedArchivePath(entry.name);
    if (path.isEmpty) continue;

    final key = path.toLowerCase();
    if (!seenPaths.add(key)) {
      throw InvalidBookException('TXTZ archive contains duplicate path "$path".');
    }

    if (!entry.isFile) continue;

    final bytes = _entryBytes(entry);
    if (bytes.length > _maxTxtzEntryBytes) {
      throw InvalidBookException('TXTZ entry "$path" is too large.');
    }

    totalBytes += bytes.length;

    if (totalBytes > _maxTxtzTotalBytes) {
      throw const InvalidBookException('TXTZ archive expands beyond the memory limit.');
    }

    files.add(_TxtzArchiveFile(path: path, bytes: bytes));
    archiveEntries.add(ArchiveEntry(path: path, size: bytes.length));
  }

  final textFiles = files.where((final file) => _isTxtzTextExtension(file.extension)).toList()
    ..sort((final a, final b) => _compareTxtzPaths(a.path, b.path));
  if (textFiles.isEmpty) {
    throw const InvalidBookException('TXTZ archive contains no text document.');
  }

  final metadataFile = _selectMetadataFile(files);
  final metadata = metadataFile == null
      ? null
      : _parseTxtzMetadata(metadataFile.bytes, metadataPath: metadataFile.path);

  return _TxtzArchiveContents(
    files: files,
    textFiles: textFiles,
    archiveEntries: archiveEntries,
    metadata: metadata,
    metadataPath: metadataFile?.path,
  );
}

/// Returns true for the TXT-family members accepted in TXTZ archives.
bool _isTxtzTextExtension(final String extension) {
  return extension == 'txt' ||
      extension == 'text' ||
      extension == 'md' ||
      extension == 'markdown' ||
      extension == 'textile';
}

/// Compares archive paths naturally (`part2` before `part10`) with a stable
/// lowercase/path tie-breaker. Archive enumeration order is not portable.
int _compareTxtzPaths(final String left, final String right) {
  final leftLower = left.toLowerCase();
  final rightLower = right.toLowerCase();

  var leftIndex = 0;
  var rightIndex = 0;
  while (leftIndex < leftLower.length && rightIndex < rightLower.length) {
    final leftCode = leftLower.codeUnitAt(leftIndex);
    final rightCode = rightLower.codeUnitAt(rightIndex);
    final leftDigit = leftCode >= 0x30 && leftCode <= 0x39;
    final rightDigit = rightCode >= 0x30 && rightCode <= 0x39;
    if (leftDigit && rightDigit) {
      final leftEnd = _digitEnd(leftLower, leftIndex);
      final rightEnd = _digitEnd(rightLower, rightIndex);
      final leftNumber = int.tryParse(leftLower.substring(leftIndex, leftEnd));
      final rightNumber = int.tryParse(rightLower.substring(rightIndex, rightEnd));
      if (leftNumber != null && rightNumber != null && leftNumber != rightNumber) {
        return leftNumber.compareTo(rightNumber);
      }

      leftIndex = leftEnd;
      rightIndex = rightEnd;
      continue;
    }
    if (leftCode != rightCode) return leftCode.compareTo(rightCode);

    leftIndex++;
    rightIndex++;
  }
  if (leftLower.length != rightLower.length) return leftLower.length.compareTo(rightLower.length);

  return left.compareTo(right);
}

/// Parses the optional OPF metadata file. Malformed metadata is deliberately
/// ignored so a TXTZ with readable text remains readable.
_TxtzMetadata? _parseTxtzMetadata(final List<int> bytes, {required final String metadataPath}) {
  try {
    final document = XmlDocument.parse(decodeXmlText(bytes));
    final elements = _elementsOf(document).toList();
    final values = _readTxtzMetadataValues(elements);

    return _TxtzMetadata(
      metadata: _buildTxtzMetadata(values),
      coverPath: _txtzCoverPath(elements, metadataPath, values),
      formatting: switch (values.formatting?.toLowerCase()) {
        'plain' || 'markdown' || 'textile' => values.formatting?.toLowerCase(),
        _ => null,
      },
    );
  } on Exception {
    return null;
  }
}

final class _TxtzMetadataValues {
  const _TxtzMetadataValues({
    required this.title,
    required this.authors,
    required this.languages,
    required this.subjects,
    required this.publisher,
    required this.description,
    required this.rights,
    required this.date,
    required this.identifiers,
    required this.identifierValues,
    required this.series,
    required this.seriesIndex,
    required this.titleSort,
    required this.authorSort,
    required this.bookProducer,
    required this.formatting,
    required this.coverHint,
    required this.coverId,
  });

  final String? title;
  final List<String> authors;
  final List<String> languages;
  final List<String> subjects;
  final String? publisher;
  final String? description;
  final String? rights;
  final DateTime? date;
  final Map<String, String> identifiers;
  final List<String> identifierValues;
  final String? series;
  final double? seriesIndex;
  final String? titleSort;
  final String? authorSort;
  final String? bookProducer;
  final String? formatting;
  final String? coverHint;
  final String? coverId;
}

_TxtzMetadataValues _readTxtzMetadataValues(final List<XmlElement> elements) {
  final creators = elements
      .where((final element) => element.name.local == 'creator' || element.name.local == 'author')
      .toList();
  final identifiers = _readTxtzIdentifiers(elements);
  final metas = elements.where((final element) => element.name.local == 'meta').toList();
  final titleElement = _firstTxtzElement(elements, 'title');
  final creatorElement = creators.isEmpty ? null : creators.first;
  String? metaValue(final Set<String> names) => _txtzMetaValue(metas, names);

  return _TxtzMetadataValues(
    title: _txtzFirstText(elements, 'title'),
    authors: _txtzAuthors(creators),
    languages: _txtzValues(elements, 'language'),
    subjects: _txtzValues(elements, 'subject'),
    publisher: _txtzFirstText(elements, 'publisher'),
    description: _txtzFirstText(elements, 'description') ?? _txtzFirstText(elements, 'comments'),
    rights: _txtzFirstText(elements, 'rights'),
    date: _parseDate(_txtzFirstText(elements, 'date')),
    identifiers: identifiers.map,
    identifierValues: identifiers.values,
    series: metaValue(<String>{'calibre:series', 'belongs-to-collection', 'series'}),
    seriesIndex: double.tryParse(
      metaValue(<String>{'calibre:series_index', 'group-position', 'series_index'}) ?? '',
    ),
    titleSort:
        metaValue(<String>{'calibre:title_sort', 'title-sort'}) ??
        titleElement?.getAttribute('file-as'),
    authorSort:
        metaValue(<String>{'calibre:author_sort', 'author-sort'}) ??
        creatorElement?.getAttribute('file-as'),
    bookProducer: metaValue(<String>{'calibre:producer', 'producer', 'generator'}),
    formatting:
        _txtzFirstText(elements, 'text-formatting') ?? metaValue(<String>{'text-formatting'}),
    coverHint: _txtzFirstText(elements, 'cover-relpath-from-base'),
    coverId: metaValue(<String>{'cover'}),
  );
}

({Map<String, String> map, List<String> values}) _readTxtzIdentifiers(
  final List<XmlElement> elements,
) {
  final map = <String, String>{};
  final values = <String>[];
  for (final identifier in elements.where((final element) => element.name.local == 'identifier')) {
    final value = identifier.innerText.trim();
    if (value.isEmpty) continue;
    values.add(value);
    final key =
        (identifier.getAttribute('scheme') ??
                identifier.getAttribute('id') ??
                'identifier-${map.length}')
            .toLowerCase();
    map.putIfAbsent(key, () => value);
  }

  return (map: map, values: values);
}

String? _txtzFirstText(final List<XmlElement> elements, final String name) {
  for (final element in elements) {
    if (element.name.local != name) continue;
    final value = element.innerText.trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}

XmlElement? _firstTxtzElement(final List<XmlElement> elements, final String name) {
  for (final element in elements) {
    if (element.name.local == name) return element;
  }

  return null;
}

List<String> _txtzAuthors(final List<XmlElement> creators) {
  final authors = <String>[];
  for (final creator in creators) {
    final value = creator.innerText.trim();
    if (value.isEmpty) continue;
    authors.addAll(
      value.split(',').map((final item) => item.trim()).where((final item) => item.isNotEmpty),
    );
  }

  return authors;
}

List<String> _txtzValues(final List<XmlElement> elements, final String name) {
  return elements
      .where((final element) => element.name.local == name)
      .map((final element) => element.innerText.trim())
      .where((final value) => value.isNotEmpty)
      .toList();
}

String? _txtzMetaValue(final List<XmlElement> metas, final Set<String> names) {
  for (final meta in metas) {
    final name = (meta.getAttribute('name') ?? meta.getAttribute('property') ?? '').toLowerCase();
    if (!names.contains(name)) continue;

    final value = (meta.getAttribute('content') ?? meta.innerText).trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}

BookMetadata _buildTxtzMetadata(final _TxtzMetadataValues values) {
  return BookMetadata(
    format: BookFormat.txtz,
    title: values.title,
    authors: values.authors,
    languages: values.languages,
    publisher: values.publisher,
    description: values.description,
    rights: values.rights,
    publishedAt: values.date,
    subjects: values.subjects,
    identifiers: values.identifiers,
    isbn: _findIsbn(values.identifierValues),
    series: values.series,
    seriesIndex: values.seriesIndex,
    titleSort: values.titleSort,
    authorSort: values.authorSort,
    bookProducer: values.bookProducer,
  );
}

String? _txtzCoverPath(
  final List<XmlElement> elements,
  final String metadataPath,
  final _TxtzMetadataValues values,
) {
  XmlElement? manifestCover;
  for (final item in elements.where((final element) => element.name.local == 'item')) {
    final properties = (item.getAttribute('properties') ?? '')
        .split(RegExp(r'\s+'))
        .map((final property) => property.toLowerCase())
        .toList();
    if (properties.contains('cover-image') || item.getAttribute('id') == values.coverId) {
      manifestCover = item;
      break;
    }
  }

  final manifestHref = manifestCover?.getAttribute('href');
  final hint = values.coverHint?.trim();

  return _resolveArchiveRelative(metadataPath, hint?.isNotEmpty == true ? hint : manifestHref);
}

String _validatedArchivePath(final String rawPath) {
  final path = rawPath.replaceAll('\\', '/');
  if (path.isEmpty) return '';
  if (path.startsWith('/') || path.contains('\u0000') || RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    throw InvalidBookException('TXTZ archive contains an unsafe path "$rawPath".');
  }

  final segments = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      throw InvalidBookException('TXTZ archive contains a path traversal entry "$rawPath".');
    }

    segments.add(segment);
  }

  return segments.join('/');
}

Uint8List _entryBytes(final ArchiveFile entry) {
  final content = entry.content;
  if (content is Uint8List) return Uint8List.sublistView(content);
  if (content is List<int>) return Uint8List.fromList(content);
  if (content is String) return Uint8List.fromList(convert.utf8.encode(content));

  throw InvalidBookException('TXTZ entry "${entry.name}" has unsupported content.');
}

_TxtzArchiveFile? _selectMetadataFile(final List<_TxtzArchiveFile> files) {
  final candidates = files.where((final file) => file.name.toLowerCase() == 'metadata.opf').toList()
    ..sort((final a, final b) {
      final aRoot = a.path.contains('/') ? 1 : 0;
      final bRoot = b.path.contains('/') ? 1 : 0;
      final rootOrder = aRoot.compareTo(bRoot);

      return rootOrder == 0 ? _compareTxtzPaths(a.path, b.path) : rootOrder;
    });

  return candidates.isEmpty ? null : candidates.first;
}

Iterable<XmlElement> _elementsOf(final XmlNode node) sync* {
  if (node is XmlElement) yield node;
  for (final child in node.children) {
    yield* _elementsOf(child);
  }
}

DateTime? _parseDate(final String? raw) {
  if (raw == null || raw.isEmpty) return null;

  final parts = RegExp(r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?(?:[T ].*)?$').firstMatch(raw);
  if (parts == null) return null;

  final year = int.parse(parts.group(1)!);
  final month = int.tryParse(parts.group(2) ?? '') ?? 1;
  final day = int.tryParse(parts.group(3) ?? '') ?? 1;
  final calendarDate = DateTime.utc(year, month, day);
  if (calendarDate.year != year || calendarDate.month != month || calendarDate.day != day) {
    return null;
  }

  return DateTime.tryParse(raw) ?? DateTime(year, month, day);
}

String? _findIsbn(final Iterable<String> values) {
  for (final value in values) {
    final compact = value.replaceAll(RegExp(r'[-\s]'), '').toUpperCase();
    if (RegExp(r'^\d{9}[\dX]$').hasMatch(compact) || RegExp(r'^97[89]\d{10}$').hasMatch(compact)) {
      return compact;
    }
  }

  return null;
}

String? _resolveArchiveRelative(final String baseFile, final String? href) {
  if (href == null || href.isEmpty) return null;

  final value = href.split('#').first.replaceAll('\\', '/');
  if (value.isEmpty || value.startsWith('/') || value.contains('\u0000') || value.contains(':')) {
    return null;
  }

  final baseSegments = baseFile.split('/');
  if (baseSegments.isNotEmpty) baseSegments.removeLast();
  for (final segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (baseSegments.isEmpty) return null;

      baseSegments.removeLast();
      continue;
    }

    baseSegments.add(segment);
  }

  return baseSegments.join('/');
}

int _digitEnd(final String value, final int start) {
  var end = start;
  while (end < value.length) {
    final code = value.codeUnitAt(end);
    if (code < 0x30 || code > 0x39) break;
    end++;
  }

  return end;
}

String _txtzExtension(final String path) {
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  if (dot <= slash || dot == path.length - 1) return '';

  return path.substring(dot + 1).toLowerCase();
}
