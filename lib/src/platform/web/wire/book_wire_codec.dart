import 'dart:typed_data';

import 'package:e_livre/src/features/comic/entities/comic_book.dart';
import 'package:e_livre/src/features/epub/entities/book/book.dart';
import 'package:e_livre/src/features/fb2/entities/fb2_book.dart';
import 'package:e_livre/src/features/mobi/entities/mobi_book.dart';
import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/pdf/entities/pdf_book.dart';
import 'package:e_livre/src/features/pdf/entities/pdf_page.dart';
import 'package:e_livre/src/features/pdf/entities/pdf_page_text.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/platform/web/wire/book_components_wire.dart';
import 'package:e_livre/src/platform/web/wire/epub_package_wire.dart';
import 'package:e_livre/src/platform/web/wire/metadata_wire.dart';

/// Encodes a fully parsed [book] into a structured-clone-friendly
/// wire payload: a JSON map holding the structure plus the flat blob
/// list it references by index. Binary content crosses as
/// [Uint8List] entries and text content (HTML/CSS file bodies) as
/// [String] entries — structured clone carries both natively, so the
/// bodies never travel inside the JSON map (no jsonEncode pass over
/// the HTML, no escaping overhead) and need no UTF-8 round-trip.
///
/// MOBI / AZW3 books cross as their parsing inputs ([mobiRecord0] +
/// [mobiIdent], the record 0 slice the original parser consumed)
/// instead of an encoded header; the receiving side re-parses it,
/// which is microsecond-cheap against the megabytes of decompression
/// the worker already absorbed.
(Map<String, Object?>, List<Object>) encodeBookWire(
  final Book book, {
  final Uint8List? mobiRecord0,
  final String? mobiIdent,
}) {
  final blobs = <Object>[];
  final json = <String, Object?>{
    'format': book.format.name,
    'navigation': encodeNavigationWireValue(book.navigation),
    'files': encodeFilesWireValue(book.files, blobs),
    'cover': encodeBinaryFileWireValue(_coverOf(book), blobs),
    'archiveEntries': <Map<String, Object?>>[
      for (final entry in book.archiveEntries)
        <String, Object?>{'path': entry.path, 'size': entry.size},
    ],
  };

  final epub = book is EpubBook ? book : null;
  if (epub != null) {
    json['epub'] = <String, Object?>{
      'spinePaths': epub.spinePaths,
      'package': encodeEpubPackageWireValue(epub.package),
    };

    return (json, blobs);
  }

  if (book is MobiBook) {
    if (mobiRecord0 == null || mobiIdent == null) {
      throw ArgumentError('MOBI books need mobiRecord0 and mobiIdent to cross the wire');
    }
    json['mobi'] = <String, Object?>{
      'ident': mobiIdent,
      'record0': pushWireBlob(blobs, mobiRecord0),
    };

    return (json, blobs);
  }

  if (book is PdfBook) {
    json['metadata'] = encodeMetadataWireValue(book.metadata, blobs);
    // The reflowed pages already crossed through the generic files
    // section; the PDF extension carries what re-derivation cannot:
    // the original bytes (facsimile mode re-serves them), the
    // per-page geometry (facsimile scaling) and the canonical text
    // lines (the facsimile text layer). Extraction never re-runs on
    // the receiving side.
    json['pdf'] = <String, Object?>{
      'bytes': pushWireBlob(blobs, book.bytes),
      'pages': <Object?>[
        for (final page in book.pages)
          <String, Object?>{
            'objectNumber': page.objectNumber,
            'mediaBox': page.mediaBox,
            'cropBox': page.cropBox,
            'rotate': page.rotate,
          },
      ],
      'pageTexts': <Object?>[
        for (final pageText in book.pageTexts)
          <String, Object?>{
            'lines': <Object?>[
              for (final line in pageText.lines)
                <String, Object?>{
                  't': line.text,
                  'x': line.x,
                  'y': line.y,
                  'w': line.width,
                  'h': line.height,
                  's': line.fontSize,
                  'r': line.rotated,
                },
            ],
          },
      ],
    };

    return (json, blobs);
  }

  if (book is DocumentBook) {
    json['metadata'] = encodeMetadataWireValue(book.metadata, blobs);
    json['document'] = <String, Object?>{'order': book.order};

    return (json, blobs);
  }

  final storedMetadata = book is Fb2Book
      ? book.metadata
      : book is ComicBook
      ? book.metadata
      : null;
  if (storedMetadata != null) {
    json['metadata'] = encodeMetadataWireValue(storedMetadata, blobs);
  }

  return (json, blobs);
}

/// Decodes a [Book] wire payload produced by [encodeBookWire].
Book decodeBookWire(final Map<String, Object?> json, final List<Object> blobs) {
  final format = BookFormat.values.byName(json['format'] as String);
  final navigation = decodeNavigationWireValue(json['navigation'] as Map<String, Object?>);
  final files = decodeFilesWireValue(json['files'] as Map<String, Object?>, blobs);
  final cover = decodeBinaryFileWireValue(json['cover'] as Map<String, Object?>?, blobs);
  final archiveEntries = decodeArchiveEntriesWireValue(json['archiveEntries'] as List<Object?>);

  final epub = json['epub'] as Map<String, Object?>?;
  if (epub != null) {
    return EpubBook(
      navigation: navigation,
      files: files,
      cover: cover,
      package: decodeEpubPackageWireValue(epub['package'] as Map<String, Object?>),
      spinePaths: (epub['spinePaths'] as List<Object?>?)?.cast<String>(),
      archiveEntries: archiveEntries,
    );
  }

  final mobi = json['mobi'] as Map<String, Object?>?;
  if (mobi != null) {
    return MobiBook(
      navigation: navigation,
      files: files,
      cover: cover,
      header: MobiHeader.parse(blobs[mobi['record0'] as int] as Uint8List, mobi['ident'] as String),
      format: format,
    );
  }

  final pdf = json['pdf'] as Map<String, Object?>?;
  if (pdf != null) {
    return PdfBook(
      bytes: blobs[pdf['bytes'] as int] as Uint8List,
      metadata: decodeMetadataWireValue(json['metadata'] as Map<String, Object?>, blobs),
      pages: <PdfPage>[
        for (final entry in pdf['pages'] as List<Object?>)
          PdfPage(
            objectNumber: (entry as Map<String, Object?>)['objectNumber'] as int,
            mediaBox: _doubleList(entry['mediaBox']),
            cropBox: entry['cropBox'] == null ? null : _doubleList(entry['cropBox']),
            rotate: (entry['rotate'] as int?) ?? 0,
          ),
      ],
      pageTexts: <PdfPageText>[
        for (final pageText in pdf['pageTexts'] as List<Object?>? ?? const <Object?>[])
          PdfPageText(
            lines: <PdfTextLine>[
              for (final line in (pageText as Map<String, Object?>)['lines'] as List<Object?>)
                PdfTextLine(
                  text: (line as Map<String, Object?>)['t'] as String,
                  x: (line['x'] as num).toDouble(),
                  y: (line['y'] as num).toDouble(),
                  width: (line['w'] as num).toDouble(),
                  height: (line['h'] as num).toDouble(),
                  fontSize: (line['s'] as num).toDouble(),
                  rotated: line['r'] as bool? ?? false,
                ),
            ],
          ),
      ],
      navigation: navigation,
      pageFiles: files.html,
      format: format,
    );
  }

  final storedMetadata = json['metadata'] as Map<String, Object?>?;
  if (storedMetadata != null) {
    final metadata = decodeMetadataWireValue(storedMetadata, blobs);
    final document = json['document'] as Map<String, Object?>?;
    if (document != null) {
      final order = (document['order'] as List<Object?>?)?.cast<String>();

      return DocumentBook(
        format: format,
        files: files,
        cover: cover.isEmpty ? null : cover,
        metadata: metadata,
        navigation: navigation,
        archiveEntries: archiveEntries,
        order: order,
      );
    }
    if (format == BookFormat.fb2) {
      return Fb2Book(navigation: navigation, files: files, cover: cover, metadata: metadata);
    }

    return ComicBook(cover: cover, metadata: metadata, pages: files.images, format: format);
  }

  throw ArgumentError('Book wire payload holds no format-specific section');
}

/// Every parsed book exposes its cover as a [BinaryFile]; the
/// abstract [Book] contract hides it behind `metadata.cover`, so the
/// concrete types are unwrapped here.
BinaryFile _coverOf(final Book book) {
  if (book is EpubBook) return book.cover;
  if (book is MobiBook) return book.cover;
  if (book is Fb2Book) return book.cover;
  if (book is ComicBook) return book.cover;
  if (book is PdfBook) return book.cover;
  if (book is DocumentBook) return book.cover ?? BinaryFile.empty();

  throw ArgumentError('Unsupported book type for the wire: ${book.runtimeType}');
}

List<double> _doubleList(final Object? json) => [
  for (final value in (json as List<Object?>)) (value as num).toDouble(),
];
