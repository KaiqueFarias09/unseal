import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/elivre_exception.dart';
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import 'archive/txtz_archive.dart';
import 'text/txt_document.dart';

/// Upper bound for a plain TXT input. The reader keeps the decoded text and
/// generated HTML in memory, so a bounded failure is safer than an accidental
/// process-wide allocation.
const int maxTxtBytes = 64 * 1024 * 1024;

/// Upper bound for the compressed TXTZ container passed to the ZIP decoder.
const int maxTxtzArchiveBytes = 128 * 1024 * 1024;

/// Parses a plain TXT document into the common [DocumentBook] model.
DocumentBook parseTxtBook(final Uint8List bytes, {final String? sourceName}) {
  _checkPlainTxtSize(bytes);
  final text = decodeTxtBytes(bytes);
  final header = txtHeaderMetadata(text, sourceName: sourceName);
  final title = header.$1 ?? '';
  final rendered = renderTxtDocument(text, title: title);
  final htmlPath = txtHtmlPath(sourceName);
  final metadata = BookMetadata(format: BookFormat.txt, title: header.$1, authors: header.$2);

  return DocumentBook(
    format: BookFormat.txt,
    files: Files(
      images: const <BinaryFile>[],
      css: const <TextFile>[],
      html: <TextFile>[
        TextFile(
          name: htmlPath.split('/').last,
          type: 'html',
          path: htmlPath,
          content: rendered.html,
        ),
      ],
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    metadata: metadata,
    navigation: Navigation(
      title: header.$1 ?? 'Contents',
      navPoints: <NavPoint>[
        _documentNavPoint(
          id: 'nav-1',
          playOrder: '1',
          label: header.$1 ?? _displayName(sourceName, fallback: 'Document'),
          content: htmlPath,
        ),
      ],
    ),
    order: <String>[htmlPath],
  );
}

/// Reads only the metadata conventionally stored at the beginning of TXT.
/// The bounded prefix keeps a multi-megabyte novel from being converted just
/// to discover its title and author.
BookMetadata readTxtMetadata(final Uint8List bytes, {final String? sourceName}) {
  final header = txtHeaderMetadata(
    decodeTxtBytes(metadataTxtPrefix(bytes)),
    sourceName: sourceName,
  );

  return BookMetadata(format: BookFormat.txt, title: header.$1, authors: header.$2);
}

/// Parses a TXTZ ZIP container. `metadata.opf` is consumed as metadata and a
/// manifest hint; it is never exposed as a reading document or independent
/// format. All text members are rendered in stable natural path order.
DocumentBook parseTxtzBook(final Uint8List bytes, {final String? sourceName}) {
  final contents = _decodeTxtz(bytes);

  return parseTxtzArchive(contents, sourceName: sourceName);
}

/// Parses already decoded TXTZ contents. This entry point is useful to tests
/// and callers that already have an [Archive] from a larger ZIP pipeline.
DocumentBook parseTxtzArchive(final TxtzArchiveContents contents, {final String? sourceName}) {
  var metadata = contents.metadata?.metadata ?? const BookMetadata(format: BookFormat.txtz);
  if (metadata.title == null || metadata.authors.isEmpty) {
    final first = txtHeaderMetadata(
      decodeTxtBytes(contents.textFiles.first.bytes),
      sourceName: sourceName ?? contents.textFiles.first.path,
    );
    metadata = metadata.copyWith(
      title: metadata.title ?? first.$1,
      authors: metadata.authors.isEmpty ? first.$2 : metadata.authors,
    );
  }

  final images = <BinaryFile>[];
  final css = <TextFile>[];
  final fonts = <BinaryFile>[];
  final others = <BinaryFile>[];
  for (final entry in contents.files) {
    if (isTxtzTextExtension(entry.extension) || entry.extension == 'opf') continue;

    final imageType = sniffImageType(entry.bytes);
    if (imageType != null) {
      images.add(
        BinaryFile(
          content: entry.bytes,
          name: entry.name,
          type: imageType.fileExtension,
          path: entry.path,
        ),
      );
      continue;
    }
    if (entry.extension == 'css') {
      css.add(
        TextFile(
          content: decodeTxtBytes(entry.bytes),
          name: entry.name,
          type: 'css',
          path: entry.path,
        ),
      );
      continue;
    }
    final isFont =
        entry.extension == 'ttf' ||
        entry.extension == 'otf' ||
        entry.extension == 'woff' ||
        entry.extension == 'woff2';
    final target = BinaryFile(
      content: entry.bytes,
      name: entry.name,
      type: entry.extension.isEmpty ? 'bin' : entry.extension,
      path: entry.path,
    );
    if (isFont) {
      fonts.add(target);
    } else {
      others.add(target);
    }
  }

  final cover = _selectCover(images, contents.metadata?.coverPath);
  if (cover != null) metadata = metadata.copyWith(cover: _bookCover(cover));

  final htmlFiles = <TextFile>[];
  final order = <String>[];
  final navPoints = <NavPoint>[];
  final outputPaths = <String>{};
  for (var index = 0; index < contents.textFiles.length; index++) {
    final entry = contents.textFiles[index];
    final path = _uniqueHtmlPath(entry.path, outputPaths);
    final formatting = contents.metadata?.formatting ?? _formattingForExtension(entry.extension);
    final entryText = decodeTxtBytes(entry.bytes);
    final entryHeader = txtHeaderMetadata(entryText, sourceName: entry.path);
    final entryTitle = index == 0 && metadata.title != null
        ? metadata.title!
        : entryHeader.$1 ?? _displayName(entry.path, fallback: 'Document ${index + 1}');
    final rendered = renderTxtDocument(entryText, title: entryTitle, formatting: formatting);
    htmlFiles.add(
      TextFile(name: path.split('/').last, type: 'html', path: path, content: rendered.html),
    );
    order.add(path);

    if (rendered.headings.isEmpty) {
      navPoints.add(
        _documentNavPoint(
          id: 'nav-${navPoints.length + 1}',
          playOrder: '${navPoints.length + 1}',
          label: entryTitle,
          content: path,
        ),
      );
    } else {
      for (final heading in rendered.headings) {
        navPoints.add(
          _documentNavPoint(
            id: 'nav-${navPoints.length + 1}',
            playOrder: '${navPoints.length + 1}',
            label: heading.label,
            content: '$path#${heading.id}',
          ),
        );
      }
    }
  }

  return DocumentBook(
    format: BookFormat.txtz,
    files: Files(images: images, css: css, html: htmlFiles, fonts: fonts, others: others),
    metadata: metadata,
    navigation: Navigation(title: metadata.title ?? 'Contents', navPoints: navPoints),
    archiveEntries: contents.archiveEntries,
    order: order,
    cover: cover,
  );
}

/// Reads metadata from a TXTZ archive without rendering text or extracting
/// resources into the [DocumentBook] model.
BookMetadata readTxtzMetadata(final Uint8List bytes, {final String? sourceName}) {
  final contents = _decodeTxtz(bytes);
  var metadata = contents.metadata?.metadata ?? const BookMetadata(format: BookFormat.txtz);
  if (metadata.title == null || metadata.authors.isEmpty) {
    final header = txtHeaderMetadata(
      decodeTxtBytes(metadataTxtPrefix(contents.textFiles.first.bytes)),
      sourceName: sourceName ?? contents.textFiles.first.path,
    );
    metadata = metadata.copyWith(
      title: metadata.title ?? header.$1,
      authors: metadata.authors.isEmpty ? header.$2 : metadata.authors,
    );
  }

  return metadata;
}

TxtzArchiveContents _decodeTxtz(final Uint8List bytes) {
  if (bytes.isEmpty) throw const InvalidBookException('Cannot parse an empty TXTZ document.');
  if (bytes.length > maxTxtzArchiveBytes) {
    throw const InvalidBookException('TXTZ archive is too large.');
  }

  try {
    return readTxtzArchive(ZipDecoder().decodeBytes(bytes));
  } on InvalidBookException {
    rethrow;
  } on Object catch (error) {
    throw InvalidBookException('Invalid TXTZ archive: $error');
  }
}

void _checkPlainTxtSize(final Uint8List bytes) {
  if (bytes.isEmpty) throw const InvalidBookException('Cannot parse an empty TXT document.');
  if (bytes.length > maxTxtBytes) throw const InvalidBookException('TXT document is too large.');
}

/// Returns the deterministic HTML path used for a TXT-family source name.
String txtHtmlPath(final String? sourceName) {
  final name = sourceName == null ? '' : sourceName.replaceAll('\\', '/');
  final safeName = name.isEmpty ? 'index' : name;
  final dot = safeName.lastIndexOf('.');
  final stem = dot > safeName.lastIndexOf('/') ? safeName.substring(0, dot) : safeName;
  return '${stem.isEmpty ? 'index' : stem}.html';
}

String _uniqueHtmlPath(final String sourcePath, final Set<String> used) {
  final base = txtHtmlPath(sourcePath);
  var candidate = base;
  var suffix = 2;
  while (!used.add(candidate.toLowerCase())) {
    final dot = base.lastIndexOf('.');
    candidate = '${base.substring(0, dot)}-$suffix.html';
    suffix++;
  }

  return candidate;
}

String _formattingForExtension(final String extension) {
  if (extension == 'md' || extension == 'markdown') return 'markdown';
  if (extension == 'textile') return 'textile';

  return 'plain';
}

String _displayName(final String? sourceName, {required final String fallback}) {
  if (sourceName == null || sourceName.isEmpty) return fallback;
  final name = sourceName.replaceAll('\\', '/').split('/').last;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;

  return stem.isEmpty ? fallback : stem;
}

BinaryFile? _selectCover(final List<BinaryFile> images, final String? requestedPath) {
  if (images.isEmpty) return null;
  if (requestedPath != null) {
    for (final image in images) {
      if (image.path.toLowerCase() == requestedPath.toLowerCase()) return image;
    }
  }
  for (final image in images) {
    if (image.name.toLowerCase().startsWith('cover')) return image;
  }

  return null;
}

BookCover? _bookCover(final BinaryFile image) {
  final type = sniffImageType(image.content);
  if (type == null) return null;
  final size = imageSize(image.content);

  return BookCover(bytes: image.content, type: type, width: size?.width, height: size?.height);
}

NavPoint _documentNavPoint({
  required final String id,
  required final String playOrder,
  required final String label,
  required final String content,
}) {
  return NavPoint(
    classAttribute: 'chapter',
    id: id,
    playOrder: playOrder,
    label: label,
    content: content,
  );
}
