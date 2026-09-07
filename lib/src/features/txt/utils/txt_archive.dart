import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';
import 'package:e_livre/src/foundation/utils/xml_encoding.dart';
import 'package:xml/xml.dart';

/// Upper bound for one uncompressed TXTZ member. This keeps a malformed
/// archive from forcing the reader to retain an unexpectedly large payload.
const int maxTxtzEntryBytes = 64 * 1024 * 1024;

/// Upper bound for the number of TXTZ members accepted by the adapter.
const int maxTxtzEntries = 10 * 1000;

/// Upper bound for the total uncompressed TXTZ payload retained by the
/// adapter after ZIP decoding.
const int maxTxtzTotalBytes = 256 * 1024 * 1024;

/// One validated file entry from a TXTZ archive.
final class TxtzArchiveFile {
  /// Creates a TXTZ entry.
  const TxtzArchiveFile({required this.path, required this.bytes});

  /// Canonical, archive-relative path.
  final String path;

  /// Uncompressed entry bytes.
  final Uint8List bytes;

  /// Lowercase extension without the dot.
  String get extension {
    final slash = path.lastIndexOf('/');
    final dot = path.lastIndexOf('.');
    if (dot <= slash || dot == path.length - 1) return '';

    return path.substring(dot + 1).toLowerCase();
  }

  /// Basename without its directory.
  String get name => path.substring(path.lastIndexOf('/') + 1);
}

/// Validated TXTZ contents, with text files selected in a deterministic
/// order and `metadata.opf` kept as package metadata rather than content.
final class TxtzArchiveContents {
  /// Creates validated TXTZ contents.
  const TxtzArchiveContents({
    required this.files,
    required this.textFiles,
    required this.archiveEntries,
    this.metadata,
    this.metadataPath,
  });

  /// Every physical file entry, including metadata and resources.
  final List<TxtzArchiveFile> files;

  /// TXT-family entries in natural path order.
  final List<TxtzArchiveFile> textFiles;

  /// Archive inventory exposed by the common document-book model.
  final List<ArchiveEntry> archiveEntries;

  /// Parsed metadata hints, when `metadata.opf` is valid.
  final TxtzMetadata? metadata;

  /// Archive path of the parsed metadata file.
  final String? metadataPath;
}

/// Metadata and conversion hints stored by Calibre's TXTZ writer.
final class TxtzMetadata {
  /// Creates TXTZ metadata.
  const TxtzMetadata({required this.metadata, this.coverPath, this.formatting});

  /// Normalized metadata mapped to eLivre's common contract.
  final BookMetadata metadata;

  /// Resolved archive path of the optional cover resource.
  final String? coverPath;

  /// `plain`, `markdown`, or `textile` when declared by the archive.
  final String? formatting;
}

/// Decodes and validates a TXTZ [archive].
TxtzArchiveContents readTxtzArchive(final Archive archive) {
  if (archive.files.length > maxTxtzEntries) {
    throw const InvalidBookException('TXTZ archive contains too many entries.');
  }

  final files = <TxtzArchiveFile>[];
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
    if (bytes.length > maxTxtzEntryBytes) {
      throw InvalidBookException('TXTZ entry "$path" is too large.');
    }
    totalBytes += bytes.length;
    if (totalBytes > maxTxtzTotalBytes) {
      throw const InvalidBookException('TXTZ archive expands beyond the memory limit.');
    }

    files.add(TxtzArchiveFile(path: path, bytes: bytes));
    archiveEntries.add(ArchiveEntry(path: path, size: bytes.length));
  }

  final textFiles = files.where((final file) => isTxtzTextExtension(file.extension)).toList()
    ..sort((final a, final b) => compareTxtzPaths(a.path, b.path));
  if (textFiles.isEmpty) {
    throw const InvalidBookException('TXTZ archive contains no text document.');
  }

  final metadataFile = _selectMetadataFile(files);
  final metadata = metadataFile == null
      ? null
      : parseTxtzMetadata(metadataFile.bytes, metadataPath: metadataFile.path);

  return TxtzArchiveContents(
    files: files,
    textFiles: textFiles,
    archiveEntries: archiveEntries,
    metadata: metadata,
    metadataPath: metadataFile?.path,
  );
}

/// Returns true for the TXT-family members that Calibre accepts in TXTZ.
bool isTxtzTextExtension(final String extension) {
  return extension == 'txt' ||
      extension == 'text' ||
      extension == 'md' ||
      extension == 'markdown' ||
      extension == 'textile';
}

/// Compares archive paths naturally (`part2` before `part10`) with a stable
/// lowercase/path tie-breaker. Archive enumeration order is not portable.
int compareTxtzPaths(final String left, final String right) {
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

/// Parses the optional Calibre OPF metadata file. Malformed metadata is
/// deliberately ignored: a TXTZ with readable text remains readable.
TxtzMetadata? parseTxtzMetadata(final List<int> bytes, {required final String metadataPath}) {
  try {
    final document = XmlDocument.parse(decodeXmlText(bytes));
    final elements = _elementsOf(document);

    String? firstText(final String name) {
      for (final element in elements) {
        if (element.name.local == name) {
          final value = element.innerText.trim();
          if (value.isNotEmpty) return value;
        }
      }
      return null;
    }

    final title = firstText('title');
    final creatorElements = elements
        .where((final e) => e.name.local == 'creator' || e.name.local == 'author')
        .toList();
    final authors = <String>[];
    for (final creator in creatorElements) {
      final value = creator.innerText.trim();
      if (value.isEmpty) continue;
      authors.addAll(
        value.split(',').map((final item) => item.trim()).where((final item) => item.isNotEmpty),
      );
    }

    final languages = elements
        .where((final e) => e.name.local == 'language')
        .map((final e) => e.innerText.trim())
        .where((final value) => value.isNotEmpty)
        .toList();
    final subjects = elements
        .where((final e) => e.name.local == 'subject')
        .map((final e) => e.innerText.trim())
        .where((final value) => value.isNotEmpty)
        .toList();
    final publisher = firstText('publisher');
    final description = firstText('description') ?? firstText('comments');
    final rights = firstText('rights');
    final date = _parseDate(firstText('date'));

    final identifiers = <String, String>{};
    final identifierValues = <String>[];
    for (final identifier in elements.where((final e) => e.name.local == 'identifier')) {
      final value = identifier.innerText.trim();
      if (value.isEmpty) continue;
      identifierValues.add(value);
      final key =
          (identifier.getAttribute('scheme') ??
                  identifier.getAttribute('id') ??
                  'identifier-${identifiers.length}')
              .toLowerCase();
      identifiers.putIfAbsent(key, () => value);
    }

    final metas = elements.where((final e) => e.name.local == 'meta').toList();
    String? metaValue(final Set<String> names) {
      for (final meta in metas) {
        final name = (meta.getAttribute('name') ?? meta.getAttribute('property') ?? '')
            .toLowerCase();
        if (!names.contains(name)) continue;
        final value = (meta.getAttribute('content') ?? meta.innerText).trim();
        if (value.isNotEmpty) return value;
      }
      return null;
    }

    final series = metaValue(<String>{'calibre:series', 'belongs-to-collection', 'series'});
    final seriesIndex = double.tryParse(
      metaValue(<String>{'calibre:series_index', 'group-position', 'series_index'}) ?? '',
    );
    final titleElements = elements.where((final e) => e.name.local == 'title').toList();
    final titleElement = titleElements.isEmpty ? null : titleElements.first;
    final authorSortElement = creatorElements.isEmpty ? null : creatorElements.first;
    final titleSort =
        metaValue(<String>{'calibre:title_sort', 'title-sort'}) ??
        titleElement?.getAttribute('file-as');
    final authorSort =
        metaValue(<String>{'calibre:author_sort', 'author-sort'}) ??
        authorSortElement?.getAttribute('file-as');
    final bookProducer = metaValue(<String>{'calibre:producer', 'producer', 'generator'});

    final formatting = (firstText('text-formatting') ?? metaValue(<String>{'text-formatting'}))
        ?.toLowerCase();
    final coverHint = firstText('cover-relpath-from-base');
    final coverId = metaValue(<String>{'cover'});
    XmlElement? manifestCover;
    for (final item in elements.where((final e) => e.name.local == 'item')) {
      final properties =
          item
              .getAttribute('properties')
              ?.split(RegExp(r'\s+'))
              .map((final property) => property.toLowerCase())
              .toList() ??
          const <String>[];
      if (properties.contains('cover-image') || item.getAttribute('id') == coverId) {
        manifestCover = item;
        break;
      }
    }
    final manifestHref = manifestCover?.getAttribute('href');
    final coverPath = _resolveArchiveRelative(
      metadataPath,
      coverHint?.trim().isNotEmpty == true ? coverHint!.trim() : manifestHref,
    );

    final metadata = BookMetadata(
      format: BookFormat.txtz,
      title: title,
      authors: authors,
      languages: languages,
      publisher: publisher,
      description: description,
      rights: rights,
      publishedAt: date,
      subjects: subjects,
      identifiers: identifiers,
      isbn: _findIsbn(identifierValues),
      series: series,
      seriesIndex: seriesIndex,
      titleSort: titleSort,
      authorSort: authorSort,
      bookProducer: bookProducer,
    );
    return TxtzMetadata(
      metadata: metadata,
      coverPath: coverPath,
      formatting: switch (formatting) {
        'plain' || 'markdown' || 'textile' => formatting,
        _ => null,
      },
    );
  } on Object {
    return null;
  }
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

TxtzArchiveFile? _selectMetadataFile(final List<TxtzArchiveFile> files) {
  final candidates = files.where((final file) => file.name.toLowerCase() == 'metadata.opf').toList()
    ..sort((final a, final b) {
      final aRoot = a.path.contains('/') ? 1 : 0;
      final bRoot = b.path.contains('/') ? 1 : 0;
      final rootOrder = aRoot.compareTo(bRoot);
      return rootOrder == 0 ? compareTxtzPaths(a.path, b.path) : rootOrder;
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
  final direct = DateTime.tryParse(raw);
  if (direct != null) return direct;
  final year = RegExp(r'^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?').firstMatch(raw);
  if (year == null) return null;

  return DateTime(
    int.parse(year.group(1)!),
    int.tryParse(year.group(2) ?? '') ?? 1,
    int.tryParse(year.group(3) ?? '') ?? 1,
  );
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
    } else {
      baseSegments.add(segment);
    }
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
