import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import '../../foundation/archive/archive_access.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import '../../foundation/text/xml_encoding.dart';

part 'archive/txtz_archive.dart';
part 'text/txt_document.dart';

/// Upper bound for a plain TXT input. The reader keeps the decoded text and
/// generated HTML in memory, so a bounded failure is safer than an accidental
/// process-wide allocation.
const _maxTxtBytes = 64 * 1024 * 1024;

/// Upper bound for the compressed TXTZ container passed to the ZIP decoder.
const _maxTxtzArchiveBytes = 128 * 1024 * 1024;

/// Parses a plain TXT document into the common [DocumentBook] model.
DocumentBook parseTxtBook(final Uint8List bytes, {final String? sourceName}) {
  _checkPlainTxtSize(bytes);
  final text = _decodeTxtBytes(bytes);
  final header = _txtHeaderMetadata(text, sourceName: sourceName);
  final rendered = _renderTxtDocument(text, title: header.title ?? '');
  final htmlPath = _txtHtmlPath(sourceName);
  final metadata = BookMetadata(
    format: BookFormat.txt,
    title: header.title,
    authors: header.authors,
  );

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
      title: header.title ?? 'Contents',
      navPoints: <NavPoint>[
        _documentNavPoint(
          id: 'nav-1',
          playOrder: '1',
          label: header.title ?? _displayName(sourceName, fallback: 'Document'),
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
  final header = _txtHeaderMetadata(
    _decodeTxtBytes(_metadataTxtPrefix(bytes)),
    sourceName: sourceName,
  );

  return BookMetadata(format: BookFormat.txt, title: header.title, authors: header.authors);
}

/// Parses a TXTZ ZIP container. `metadata.opf` is consumed as metadata and a
/// manifest hint; it is never exposed as a reading document or independent
/// format. All text members are rendered in stable natural path order.
DocumentBook parseTxtzBook(final Uint8List bytes, {final String? sourceName}) {
  final contents = _decodeTxtz(bytes);

  return _parseTxtzContents(contents, sourceName: sourceName);
}

/// Whether [archive] contains at least one TXTZ text member.
///
/// This package-internal seam lets the reading dispatcher classify a ZIP
/// container without duplicating the TXTZ format boundary.
bool isTxtzArchive(final Archive archive) {
  return archive.files.any(
    (final file) => file.isFile && _isTxtzTextExtension(_txtzExtension(file.name)),
  );
}

/// Parses a TXTZ archive already decoded by a ZIP dispatch pipeline.
///
/// This package-internal seam avoids decoding the same archive twice. It is
/// intentionally omitted from the public `txt.dart` library.
DocumentBook parseTxtzArchive(final Archive archive, {final String? sourceName}) {
  return _parseTxtzContents(_readTxtzArchive(archive), sourceName: sourceName);
}

DocumentBook _parseTxtzContents(final _TxtzArchiveContents contents, {final String? sourceName}) {
  var metadata = _txtzMetadataWithHeader(contents, sourceName: sourceName);
  final resources = _collectTxtzResources(contents.files);
  final cover = _selectCover(resources.images, contents.metadata?.coverPath);
  if (cover != null) metadata = metadata.copyWith(cover: _bookCover(cover));
  final rendered = _renderTxtzFiles(contents, metadata);

  return DocumentBook(
    format: BookFormat.txtz,
    files: Files(
      images: resources.images,
      css: resources.css,
      html: rendered.htmlFiles,
      fonts: resources.fonts,
      others: resources.others,
    ),
    metadata: metadata,
    navigation: Navigation(title: metadata.title ?? 'Contents', navPoints: rendered.navPoints),
    archiveEntries: contents.archiveEntries,
    order: rendered.order,
    cover: cover,
  );
}

BookMetadata _txtzMetadataWithHeader(
  final _TxtzArchiveContents contents, {
  required final String? sourceName,
}) {
  var metadata = contents.metadata?.metadata ?? const BookMetadata(format: BookFormat.txtz);
  if (metadata.title == null && metadata.authors.isEmpty) {
    final first = _txtHeaderMetadata(
      _decodeTxtBytes(contents.textFiles.first.bytes),
      sourceName: sourceName ?? contents.textFiles.first.path,
    );

    return metadata.copyWith(title: first.title, authors: first.authors);
  }
  if (metadata.title == null || metadata.authors.isEmpty) {
    final first = _txtHeaderMetadata(
      _decodeTxtBytes(contents.textFiles.first.bytes),
      sourceName: sourceName ?? contents.textFiles.first.path,
    );
    metadata = metadata.copyWith(
      title: metadata.title ?? first.title,
      authors: metadata.authors.isEmpty ? first.authors : metadata.authors,
    );
  }

  return metadata;
}

final class _TxtzResources {
  const _TxtzResources({
    required this.images,
    required this.css,
    required this.fonts,
    required this.others,
  });

  final List<BinaryFile> images;
  final List<TextFile> css;
  final List<BinaryFile> fonts;
  final List<BinaryFile> others;
}

_TxtzResources _collectTxtzResources(final List<_TxtzArchiveFile> files) {
  final images = <BinaryFile>[];
  final css = <TextFile>[];
  final fonts = <BinaryFile>[];
  final others = <BinaryFile>[];
  for (final entry in files) {
    if (_isTxtzTextExtension(entry.extension) || entry.extension == 'opf') continue;
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
          content: _decodeTxtBytes(entry.bytes),
          name: entry.name,
          type: 'css',
          path: entry.path,
        ),
      );

      continue;
    }
    final target = BinaryFile(
      content: entry.bytes,
      name: entry.name,
      type: entry.extension.isEmpty ? 'bin' : entry.extension,
      path: entry.path,
    );
    if (_isTxtzFont(entry.extension)) {
      fonts.add(target);
    } else {
      others.add(target);
    }
  }

  return _TxtzResources(images: images, css: css, fonts: fonts, others: others);
}

bool _isTxtzFont(final String extension) {
  return extension == 'ttf' || extension == 'otf' || extension == 'woff' || extension == 'woff2';
}

final class _RenderedTxtzFiles {
  const _RenderedTxtzFiles({required this.htmlFiles, required this.order, required this.navPoints});

  final List<TextFile> htmlFiles;
  final List<String> order;
  final List<NavPoint> navPoints;
}

_RenderedTxtzFiles _renderTxtzFiles(
  final _TxtzArchiveContents contents,
  final BookMetadata metadata,
) {
  final htmlFiles = <TextFile>[];
  final order = <String>[];
  final navPoints = <NavPoint>[];
  final outputPaths = <String>{};
  for (var index = 0; index < contents.textFiles.length; index++) {
    final entry = contents.textFiles[index];
    final path = _uniqueHtmlPath(entry.path, outputPaths);
    final formatting = contents.metadata?.formatting ?? _formattingForExtension(entry.extension);
    final entryText = _decodeTxtBytes(entry.bytes);
    final entryHeader = _txtHeaderMetadata(entryText, sourceName: entry.path);
    final entryTitle = index == 0 && metadata.title != null
        ? metadata.title!
        : entryHeader.title ?? _displayName(entry.path, fallback: 'Document ${index + 1}');
    final rendered = _renderTxtDocument(entryText, title: entryTitle, formatting: formatting);
    htmlFiles.add(
      TextFile(name: path.split('/').last, type: 'html', path: path, content: rendered.html),
    );
    order.add(path);
    _addTxtzNavigation(navPoints, rendered.headings, entryTitle, path);
  }

  return _RenderedTxtzFiles(htmlFiles: htmlFiles, order: order, navPoints: navPoints);
}

void _addTxtzNavigation(
  final List<NavPoint> navPoints,
  final List<_TxtHeading> headings,
  final String entryTitle,
  final String path,
) {
  if (headings.isEmpty) {
    navPoints.add(
      _documentNavPoint(
        id: 'nav-${navPoints.length + 1}',
        playOrder: '${navPoints.length + 1}',
        label: entryTitle,
        content: path,
      ),
    );

    return;
  }
  for (final heading in headings) {
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

/// Reads metadata from a TXTZ archive without rendering text or extracting
/// resources into the [DocumentBook] model.
BookMetadata readTxtzMetadata(final Uint8List bytes, {final String? sourceName}) {
  return _readTxtzContentsMetadata(_decodeTxtz(bytes), sourceName: sourceName);
}

/// Reads metadata from a TXTZ archive already decoded by a ZIP dispatch pipeline.
///
/// This package-internal seam is intentionally omitted from `txt.dart`.
BookMetadata readTxtzMetadataFromArchive(final Archive archive, {final String? sourceName}) {
  return _readTxtzContentsMetadata(_readTxtzArchive(archive), sourceName: sourceName);
}

BookMetadata _readTxtzContentsMetadata(
  final _TxtzArchiveContents contents, {
  final String? sourceName,
}) {
  var metadata = contents.metadata?.metadata ?? const BookMetadata(format: BookFormat.txtz);
  if (metadata.title == null || metadata.authors.isEmpty) {
    final header = _txtHeaderMetadata(
      _decodeTxtBytes(_metadataTxtPrefix(contents.textFiles.first.bytes)),
      sourceName: sourceName ?? contents.textFiles.first.path,
    );
    metadata = metadata.copyWith(
      title: metadata.title ?? header.title,
      authors: metadata.authors.isEmpty ? header.authors : metadata.authors,
    );
  }

  return metadata;
}

_TxtzArchiveContents _decodeTxtz(final Uint8List bytes) {
  if (bytes.isEmpty) throw const InvalidBookException('Cannot parse an empty TXTZ document.');
  if (bytes.length > _maxTxtzArchiveBytes) {
    throw const InvalidBookException('TXTZ archive is too large.');
  }

  try {
    return _readTxtzArchive(decodeBookZip(bytes));
  } on InvalidBookException {
    rethrow;
  } on Exception catch (error) {
    throw InvalidBookException('Invalid TXTZ archive: $error');
  }
}

void _checkPlainTxtSize(final Uint8List bytes) {
  if (bytes.isEmpty) throw const InvalidBookException('Cannot parse an empty TXT document.');
  if (bytes.length > _maxTxtBytes) throw const InvalidBookException('TXT document is too large.');
}

String _txtHtmlPath(final String? sourceName) {
  final name = sourceName == null ? '' : sourceName.replaceAll('\\', '/');
  final safeName = name.isEmpty ? 'index' : name;
  final dot = safeName.lastIndexOf('.');
  final stem = dot > safeName.lastIndexOf('/') ? safeName.substring(0, dot) : safeName;

  return '${stem.isEmpty ? 'index' : stem}.html';
}

String _uniqueHtmlPath(final String sourcePath, final Set<String> used) {
  final base = _txtHtmlPath(sourcePath);
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
