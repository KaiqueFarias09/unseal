import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:e_livre/src/features/cfi/epub_cfi_resolver.dart';
import 'package:e_livre/src/features/comic/entities/comic_book.dart';
import 'package:e_livre/src/features/comic/exceptions/comic_exception.dart';
import 'package:e_livre/src/features/epub/entities/book/book.dart';
import 'package:e_livre/src/features/epub/entities/package/epub_2_package.dart';
import 'package:e_livre/src/features/epub/entities/package/epub_3_package.dart';
import 'package:e_livre/src/features/epub/entities/package/epub_package.dart';
import 'package:e_livre/src/features/epub/entities/package/page_progression_direction.dart';
import 'package:e_livre/src/features/epub/exceptions/empty_bytes_exception.dart';
import 'package:e_livre/src/features/epub/exceptions/epub_exception.dart';
import 'package:e_livre/src/features/fb2/entities/fb2_book.dart';
import 'package:e_livre/src/features/fb2/exceptions/fb2_exception.dart';
import 'package:e_livre/src/features/mobi/entities/mobi_book.dart';
import 'package:e_livre/src/features/mobi/exceptions/mobi_exception.dart';
import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/features/pdf/entities/pdf_book.dart';
import 'package:e_livre/src/features/pdf/entities/pdf_page.dart';
import 'package:e_livre/src/features/pdf/exceptions/pdf_exception.dart';
import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/features/search/book_search.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';

/// Wire protocol op: parse a whole book.
const String workerOpParse = 'parse';

/// Wire protocol op: extract metadata only.
const String workerOpMetadata = 'metadata';

/// Wire protocol op: full-text search over the resident book.
const String workerOpSearch = 'search';

/// Wire protocol op: resolve a CFI against the resident book.
const String workerOpCfiResolve = 'cfiResolve';

/// Wire protocol op: build a CFI from a reading position in the
/// resident book.
const String workerOpCfiBuild = 'cfiBuild';

/// Wire protocol reply kind: a decoded [Book].
const String wireReplyBook = 'book';

/// Wire protocol reply kind: decoded [BookMetadata].
const String wireReplyMetadata = 'metadata';

/// Wire protocol reply kind: encoded [SearchResults].
const String wireReplySearch = 'search';

/// Wire protocol reply kind: an encoded [EpubCfiLocation] (JSON null
/// when the CFI resolves nowhere).
const String wireReplyCfiLocation = 'cfiLocation';

/// Wire protocol reply kind: an encoded CFI string.
const String wireReplyCfi = 'cfi';

/// Wire protocol reply kind: a parse failure.
const String wireReplyError = 'error';

/// Wire protocol key: request id echoed back on every reply.
const String wireKeyId = 'id';

/// Wire protocol key: requested operation.
const String wireKeyOp = 'op';

/// Wire protocol key: the book bytes sent by the main thread.
const String wireKeyBytes = 'bytes';

/// Wire protocol key: the JSON-encoded op payload the stateful ops
/// read their arguments from; carried next to [wireKeyBytes], either
/// side may be absent.
const String wireKeyPayload = 'payload';

/// Wire protocol key: reply discriminator.
const String wireKeyKind = 'kind';

/// Wire protocol key: the JSON half of a wire payload.
const String wireKeyJson = 'json';

/// Wire protocol key: the blob half of a wire payload — the flat list
/// of payloads the JSON map references by index. Entries are
/// [Uint8List] (binary content) or [String] (text content); structured
/// clone carries both natively, so text crosses without a UTF-8
/// round-trip.
const String wireKeyBlobs = 'blobs';

/// Wire protocol key: exception type name on error replies.
const String wireKeyType = 'type';

/// Wire protocol key: exception message on error replies.
const String wireKeyMessage = 'message';

/// Op payload key: the search query.
const String wireKeyQuery = 'query';

/// Op payload key: the [SearchMode] enum name.
const String wireKeyMode = 'mode';

/// Op payload key: whether the search folds case.
const String wireKeyCaseSensitive = 'caseSensitive';

/// Op payload key: whether the search tolerates typesetting noise.
const String wireKeyTolerant = 'tolerant';

/// Op payload key: the proximity interval in characters.
const String wireKeyNearChars = 'nearChars';

/// Op payload key: the snippet context radius in characters.
const String wireKeyContextChars = 'contextChars';

/// Op payload key: the match cap.
const String wireKeyMaxMatches = 'maxMatches';

/// Op payload key: the CFI string (request) or the built CFI string
/// (reply of [workerOpCfiBuild]).
const String wireKeyCfi = 'cfi';

/// Op payload key: the reading-order section index.
const String wireKeyContentIndex = 'contentIndex';

/// Op payload key: the offset inside the section's document text.
const String wireKeyOffsetInText = 'offsetInText';

/// Reply key: the encoded [EpubCfiLocation], JSON null when the CFI
/// resolved nowhere.
const String wireKeyLocation = 'location';

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
    'navigation': _encodeNavigation(book.navigation),
    'files': _encodeFiles(book.files, blobs),
    'cover': _encodeBinaryFile(_coverOf(book), blobs),
    'archiveEntries': <Map<String, Object?>>[
      for (final entry in book.archiveEntries)
        <String, Object?>{'path': entry.path, 'size': entry.size},
    ],
  };

  final epub = book is EpubBook ? book : null;
  if (epub != null) {
    json['epub'] = <String, Object?>{
      'spinePaths': epub.spinePaths,
      'package': _encodePackage(epub.package),
    };

    return (json, blobs);
  }

  if (book is MobiBook) {
    if (mobiRecord0 == null || mobiIdent == null) {
      throw ArgumentError('MOBI books need mobiRecord0 and mobiIdent to cross the wire');
    }
    json['mobi'] = <String, Object?>{'ident': mobiIdent, 'record0': _pushBlob(blobs, mobiRecord0)};

    return (json, blobs);
  }

  if (book is PdfBook) {
    json['metadata'] = _encodeMetadata(book.metadata, blobs);
    // The reflowed pages already crossed through the generic files
    // section; the PDF extension carries what re-derivation cannot:
    // the original bytes (facsimile mode re-serves them) and the
    // per-page geometry (facsimile scaling). Extraction never re-runs
    // on the receiving side.
    json['pdf'] = <String, Object?>{
      'bytes': _pushBlob(blobs, book.bytes),
      'pages': <Object?>[
        for (final page in book.pages)
          <String, Object?>{
            'objectNumber': page.objectNumber,
            'mediaBox': page.mediaBox,
            'cropBox': page.cropBox,
            'rotate': page.rotate,
          },
      ],
    };

    return (json, blobs);
  }

  final storedMetadata = book is Fb2Book
      ? book.metadata
      : book is ComicBook
      ? book.metadata
      : null;
  if (storedMetadata != null) {
    json['metadata'] = _encodeMetadata(storedMetadata, blobs);
  }

  return (json, blobs);
}

/// Encodes format-agnostic [metadata] into a wire payload.
(Map<String, Object?>, List<Object>) encodeMetadataWire(final BookMetadata metadata) {
  final blobs = <Object>[];

  return (_encodeMetadata(metadata, blobs), blobs);
}

/// Decodes a [Book] wire payload produced by [encodeBookWire].
Book decodeBookWire(final Map<String, Object?> json, final List<Object> blobs) {
  final format = BookFormat.values.byName(json['format'] as String);
  final navigation = _decodeNavigation(json['navigation'] as Map<String, Object?>);
  final files = _decodeFiles(json['files'] as Map<String, Object?>, blobs);
  final cover = _decodeBinaryFile(json['cover'] as Map<String, Object?>?, blobs);
  final archiveEntries = _decodeArchiveEntries(json['archiveEntries'] as List<Object?>);

  final epub = json['epub'] as Map<String, Object?>?;
  if (epub != null) {
    return EpubBook(
      navigation: navigation,
      files: files,
      cover: cover,
      package: _decodePackage(epub['package'] as Map<String, Object?>),
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
      metadata: _decodeMetadata(json['metadata'] as Map<String, Object?>, blobs),
      pages: <PdfPage>[
        for (final entry in pdf['pages'] as List<Object?>)
          PdfPage(
            objectNumber: (entry as Map<String, Object?>)['objectNumber'] as int,
            mediaBox: _doubleList(entry['mediaBox']),
            cropBox: entry['cropBox'] == null ? null : _doubleList(entry['cropBox']),
            rotate: (entry['rotate'] as int?) ?? 0,
          ),
      ],
      navigation: navigation,
      pageFiles: files.html,
    );
  }

  final storedMetadata = json['metadata'] as Map<String, Object?>?;
  if (storedMetadata != null) {
    final metadata = _decodeMetadata(storedMetadata, blobs);
    if (format == BookFormat.fb2) {
      return Fb2Book(navigation: navigation, files: files, cover: cover, metadata: metadata);
    }

    return ComicBook(cover: cover, metadata: metadata, pages: files.images, format: format);
  }

  throw ArgumentError('Book wire payload holds no format-specific section');
}

/// Decodes a [BookMetadata] wire payload produced by
/// [encodeMetadataWire].
BookMetadata decodeMetadataWire(final Map<String, Object?> json, final List<Object> blobs) =>
    _decodeMetadata(json, blobs);

/// Encodes [results] into a wire payload. No blobs: matches carry
/// text only.
Map<String, Object?> encodeSearchResultsWire(final SearchResults results) => <String, Object?>{
  'query': results.query,
  'truncated': results.truncated,
  'matches': <Object?>[for (final match in results.matches) _encodeSearchMatch(match)],
};

/// Decodes a [SearchResults] wire payload produced by
/// [encodeSearchResultsWire].
SearchResults decodeSearchResultsWire(final Map<String, Object?> json) => SearchResults(
  query: json['query'] as String,
  truncated: json['truncated'] as bool,
  matches: <SearchMatch>[
    for (final match in json['matches'] as List<Object?>)
      _decodeSearchMatch(match as Map<String, Object?>),
  ],
);

Map<String, Object?> _encodeSearchMatch(final SearchMatch match) => <String, Object?>{
  'sectionIndex': match.sectionIndex,
  'sectionName': match.sectionName,
  'start': match.start,
  'end': match.end,
  'snippet': match.snippet,
};

SearchMatch _decodeSearchMatch(final Map<String, Object?> json) => SearchMatch(
  sectionIndex: json['sectionIndex'] as int,
  sectionName: json['sectionName'] as String,
  start: json['start'] as int,
  end: json['end'] as int,
  snippet: json['snippet'] as String,
);

/// Encodes a resolved CFI [location] into a wire payload; `null`
/// (the CFI resolved nowhere) travels as JSON null. Every field is
/// written explicitly so a field added to [EpubCfiLocation] shows up
/// as a visible diff here.
Map<String, Object?>? encodeCfiLocationWire(final EpubCfiLocation? location) => location == null
    ? null
    : <String, Object?>{
        'contentIndex': location.contentIndex,
        'contentPath': location.contentPath,
        'charOffset': location.charOffset,
        'endCharOffset': location.endCharOffset,
        'textExcerpt': location.textExcerpt,
        'elementTrail': List<String>.of(location.elementTrail),
      };

/// Decodes an [EpubCfiLocation] wire payload produced by
/// [encodeCfiLocationWire]; `null` means the CFI resolved nowhere.
EpubCfiLocation? decodeCfiLocationWire(final Map<String, Object?>? json) => json == null
    ? null
    : EpubCfiLocation(
        contentIndex: json['contentIndex'] as int,
        contentPath: json['contentPath'] as String,
        charOffset: json['charOffset'] as int?,
        endCharOffset: json['endCharOffset'] as int?,
        textExcerpt: json['textExcerpt'] as String?,
        elementTrail: (json['elementTrail'] as List<Object?>?)?.cast<String>() ?? const <String>[],
      );

/// The PDB record slice the MOBI parser consumed as its header.
///
/// Plain MOBI 6 and standalone KF8 (AZW3) books parse record 0, but a
/// joint MOBI 6 + KF8 file parses the KF8 header found past the
/// BOUNDARY record (EXTH 121), so the wire must cross that slice —
/// crossing raw record 0 would make the receiving side re-parse the
/// wrong half (wrong flavor, wrong chapter and resource indexes).
Uint8List mobiWireRecord0(final Uint8List bytes) {
  final pdb = PdbHeader.parse(bytes);
  final header = MobiHeader.parse(pdb.record(0), pdb.ident);
  if (header.mobiVersion != 8 || header.skelIndex == nullIndex) {
    final k8i = header.exth?.kf8HeaderIndex;
    if (k8i != null && k8i >= 1 && k8i - 1 < pdb.count) {
      final boundary = pdb.record(k8i - 1);
      if (boundary.length >= 8 && String.fromCharCodes(boundary.sublist(0, 8)) == 'BOUNDARY') {
        return pdb.record(k8i);
      }
    }
  }

  return pdb.record(0);
}

/// Rebuilds the exception hierarchy behind a worker error reply:
/// known [ELivreException] subtypes come back with their own type,
/// [FormatException] (a bad regex query) keeps its own type, unknown
/// ones degrade to the base exception with the original text
/// preserved.
Exception decodeErrorWire(final String type, final String message) {
  switch (type) {
    case 'EmptyBytesException':
      return EmptyBytesException();
    case 'FormatException':
      return FormatException(message);
    case 'FormatNotSupportedException':
      return FormatNotSupportedException(message);
    case 'DrmProtectedException':
      return DrmProtectedException(message);
    case 'InvalidBookException':
      return InvalidBookException(message);
    case 'EpubException':
      return EpubException(message);
    case 'MobiException':
      return MobiException(message);
    case 'Fb2Exception':
      return Fb2Exception(message);
    case 'ComicException':
      return ComicException(message);
    case 'PdfException':
      return PdfException(message);
    case 'PdfEncryptedException':
      return const PdfEncryptedException();
    default:
      return ELivreException(message);
  }
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

  throw ArgumentError('Unsupported book type for the wire: ${book.runtimeType}');
}

List<double> _doubleList(final Object? json) => [
  for (final value in (json as List<Object?>)) (value as num).toDouble(),
];

Map<String, Object?> _encodeNavigation(final Navigation navigation) => <String, Object?>{
  'title': navigation.title,
  'points': <Object?>[for (final point in navigation.navPoints) _encodeNavPoint(point)],
};

Map<String, Object?> _encodeNavPoint(final NavPoint point) => <String, Object?>{
  'classAttribute': point.classAttribute,
  'id': point.id,
  'playOrder': point.playOrder,
  'label': point.label,
  'content': point.content,
  'subNavPoints': <Object?>[for (final sub in point.subNavPoints) _encodeNavPoint(sub)],
};

Navigation _decodeNavigation(final Map<String, Object?> json) => Navigation(
  title: json['title'] as String,
  navPoints: <NavPoint>[
    for (final point in json['points'] as List<Object?>)
      _decodeNavPoint(point as Map<String, Object?>),
  ],
);

NavPoint _decodeNavPoint(final Map<String, Object?> json) => NavPoint(
  classAttribute: json['classAttribute'] as String,
  id: json['id'] as String,
  playOrder: json['playOrder'] as String,
  label: json['label'] as String,
  content: json['content'] as String,
  subNavPoints: <NavPoint>[
    for (final sub in json['subNavPoints'] as List<Object?>)
      _decodeNavPoint(sub as Map<String, Object?>),
  ],
);

Map<String, Object?> _encodeFiles(final Files files, final List<Object> blobs) => <String, Object?>{
  'html': <Object?>[for (final file in files.html) _encodeTextFile(file, blobs)],
  'css': <Object?>[for (final file in files.css) _encodeTextFile(file, blobs)],
  'images': <Object?>[for (final file in files.images) _encodeBinaryFile(file, blobs)],
  'fonts': <Object?>[for (final file in files.fonts) _encodeBinaryFile(file, blobs)],
  'others': <Object?>[for (final file in files.others) _encodeBinaryFile(file, blobs)],
};

Files _decodeFiles(final Map<String, Object?> json, final List<Object> blobs) => Files(
  html: _decodeTextFiles(json['html'] as List<Object?>, blobs),
  css: _decodeTextFiles(json['css'] as List<Object?>, blobs),
  images: _decodeBinaryFiles(json['images'] as List<Object?>, blobs),
  fonts: _decodeBinaryFiles(json['fonts'] as List<Object?>, blobs),
  others: _decodeBinaryFiles(json['others'] as List<Object?>, blobs),
);

Map<String, Object?> _encodeTextFile(final TextFile file, final List<Object> blobs) =>
    <String, Object?>{
      'path': file.path,
      'name': file.name,
      'type': file.type,
      'blob': _pushBlob(blobs, file.content),
    };

TextFile _decodeTextFile(final Map<String, Object?> json, final List<Object> blobs) => TextFile(
  path: json['path'] as String,
  name: json['name'] as String,
  type: json['type'] as String,
  content: blobs[json['blob'] as int] as String,
);

List<TextFile> _decodeTextFiles(final List<Object?> json, final List<Object> blobs) => <TextFile>[
  for (final file in json) _decodeTextFile(file as Map<String, Object?>, blobs),
];

Map<String, Object?> _encodeBinaryFile(final BinaryFile file, final List<Object> blobs) =>
    <String, Object?>{
      'path': file.path,
      'name': file.name,
      'type': file.type,
      'blob': _pushBlob(blobs, file.content),
    };

BinaryFile _decodeBinaryFile(final Map<String, Object?>? json, final List<Object> blobs) =>
    json == null
    ? BinaryFile.empty()
    : BinaryFile(
        path: json['path'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        content: blobs[json['blob'] as int] as Uint8List,
      );

List<BinaryFile> _decodeBinaryFiles(final List<Object?> json, final List<Object> blobs) =>
    <BinaryFile>[for (final file in json) _decodeBinaryFile(file as Map<String, Object?>, blobs)];

List<ArchiveEntry> _decodeArchiveEntries(final List<Object?> json) => <ArchiveEntry>[
  for (final entry in json)
    ArchiveEntry(
      path: (entry as Map<String, Object?>)['path'] as String,
      size: entry['size'] as int,
    ),
];

/// Appends a blob payload (binary bytes or a text string) and returns
/// the index the JSON map must reference.
int _pushBlob(final List<Object> blobs, final Object payload) {
  blobs.add(payload);

  return blobs.length - 1;
}

Map<String, Object?> _encodeMetadata(final BookMetadata metadata, final List<Object> blobs) =>
    <String, Object?>{
      'format': metadata.format.name,
      'title': metadata.title,
      'titleSort': metadata.titleSort,
      'authorSort': metadata.authorSort,
      'bookProducer': metadata.bookProducer,
      'publisher': metadata.publisher,
      'description': metadata.description,
      'isbn': metadata.isbn,
      'rights': metadata.rights,
      'series': metadata.series,
      'seriesIndex': metadata.seriesIndex,
      'publishedAt': metadata.publishedAt?.toIso8601String(),
      'authors': List<String>.of(metadata.authors),
      'languages': List<String>.of(metadata.languages),
      'subjects': List<String>.of(metadata.subjects),
      'identifiers': Map<String, String>.of(metadata.identifiers),
      'cover': metadata.cover == null
          ? null
          : <String, Object?>{
              'blob': _pushBlob(blobs, metadata.cover!.bytes),
              'type': metadata.cover!.type.name,
              'width': metadata.cover!.width,
              'height': metadata.cover!.height,
            },
    };

BookMetadata _decodeMetadata(final Map<String, Object?> json, final List<Object> blobs) {
  final cover = json['cover'] as Map<String, Object?>?;

  return BookMetadata(
    format: BookFormat.values.byName(json['format'] as String),
    title: json['title'] as String?,
    titleSort: json['titleSort'] as String?,
    authorSort: json['authorSort'] as String?,
    bookProducer: json['bookProducer'] as String?,
    publisher: json['publisher'] as String?,
    description: json['description'] as String?,
    isbn: json['isbn'] as String?,
    rights: json['rights'] as String?,
    series: json['series'] as String?,
    seriesIndex: (json['seriesIndex'] as num?)?.toDouble(),
    publishedAt: json['publishedAt'] == null ? null : DateTime.parse(json['publishedAt'] as String),
    authors: (json['authors'] as List<Object?>).cast<String>(),
    languages: (json['languages'] as List<Object?>).cast<String>(),
    subjects: (json['subjects'] as List<Object?>).cast<String>(),
    identifiers: (json['identifiers'] as Map<Object?, Object?>).cast<String, String>(),
    cover: cover == null
        ? null
        : BookCover(
            bytes: blobs[cover['blob'] as int] as Uint8List,
            type: ImageType.values.byName(cover['type'] as String),
            width: cover['width'] as int?,
            height: cover['height'] as int?,
          ),
  );
}

Map<String, Object?> _encodePackage(final EpubPackage package) => <String, Object?>{
  'kind': package is Epub3Package ? 3 : 2,
  'version': package.version,
  'xmlns': package.xmlns,
  'uniqueIdentifier': package.uniqueIdentifier,
  'tocId': package is Epub3Package ? package.tocId : null,
  'metadata': _encodePackageMetadata(package),
  'manifest': <String, Object?>{
    'kind': package.manifest is Epub3Manifest ? 3 : 2,
    'items': <Object?>[
      for (final item in package.manifest.items)
        <String, Object?>{
          'path': item.path,
          'id': item.id,
          'mediaType': item.mediaType,
          'properties': List<String>.of(item.properties),
          'mediaOverlay': item.mediaOverlay,
        },
    ],
    'properties': package.manifest is Epub3Manifest
        ? (package.manifest as Epub3Manifest).properties
        : null,
  },
  'spine': <String, Object?>{
    'tocId': package.spine.tocId,
    'items': List<String>.of(package.spine.items),
    'pageProgressionDirection': package.spine.pageProgressionDirection.name,
  },
  'guide': package.guide == null
      ? null
      : <String, Object?>{
          'references': <Object?>[
            for (final reference in package.guide!.references)
              <String, Object?>{
                'href': reference.href,
                'title': reference.title,
                'type': reference.type,
              },
          ],
        },
};

Map<String, Object?> _encodePackageMetadata(final EpubPackage package) {
  final metadata = package.metadata;

  return <String, Object?>{
    'kind': metadata is Epub3Metadata ? 3 : 2,
    'title': metadata.title,
    'date': metadata.date,
    'language': metadata.language,
    'identifiers': List<String>.of(metadata.identifiers),
    'uniqueIdentifierValue': metadata.uniqueIdentifierValue,
    'subject': metadata.subject,
    'description': metadata.description,
    'rights': metadata.rights == null ? null : List<String>.of(metadata.rights!),
    'contributor': metadata.contributor,
    'creator': metadata.creator,
    'publisher': metadata.publisher,
    'coverId': metadata.coverId,
    'series': metadata.series,
    'seriesIndex': metadata.seriesIndex,
    'titleSort': metadata.titleSort,
    'authorSort': metadata.authorSort,
    'bookProducer': metadata.bookProducer,
    if (metadata is Epub3Metadata) ...<String, Object?>{
      'schemaOrgs': List<String>.of(metadata.schemaOrgs),
      'accessibilitySummaries': List<String>.of(metadata.accessibilitySummaries),
      'accessibilityFeatures': List<String>.of(metadata.accessibilityFeatures),
      'educationalRole': metadata.educationalRole,
      'typicalAgeRange': metadata.typicalAgeRange,
      'modified': metadata.modified,
      'rendition': metadata.rendition,
      'belongsToCollection': metadata.belongsToCollection,
      'sourceOf': metadata.sourceOf,
      'recordIdentifier': metadata.recordIdentifier,
      'mediaDuration': metadata.mediaDuration,
      'mediaActiveClass': metadata.mediaActiveClass,
      'mediaPlaybackActiveClass': metadata.mediaPlaybackActiveClass,
      'narrator': metadata.narrator,
    },
  };
}

EpubPackage _decodePackage(final Map<String, Object?> json) {
  final isEpub3 = json['kind'] == 3;
  // Manifest and metadata flavors travel with their own kind: a real
  // file can mix them (an EPUB 3 package may carry an EPUB 2 manifest
  // when its items declare no `properties`), so they never inherit the
  // package flavor.
  final manifestJson = json['manifest'] as Map<String, Object?>;
  final manifest = manifestJson['kind'] == 3
      ? Epub3Manifest(
          items: _decodeManifestItems(manifestJson['items'] as List<Object?>),
          properties: (manifestJson['properties'] as String?) ?? '',
        )
      : Epub2Manifest(items: _decodeManifestItems(manifestJson['items'] as List<Object?>));
  final metadataJson = json['metadata'] as Map<String, Object?>;
  final metadata = metadataJson['kind'] == 3
      ? _decodeEpub3Metadata(metadataJson)
      : _decodeEpub2Metadata(metadataJson);
  final guideJson = json['guide'] as Map<String, Object?>?;
  final guide = guideJson == null
      ? null
      : Guide(
          references: <Reference>[
            for (final reference in guideJson['references'] as List<Object?>)
              _decodeReference(reference as Map<String, Object?>),
          ],
        );
  final spineJson = json['spine'] as Map<String, Object?>;

  return isEpub3
      ? Epub3Package(
          version: json['version'] as String,
          xmlns: json['xmlns'] as String?,
          uniqueIdentifier: json['uniqueIdentifier'] as String,
          metadata: metadata,
          manifest: manifest,
          spine: _decodeSpine(spineJson),
          tocId: json['tocId'] as String?,
          guide: guide,
        )
      : Epub2Package(
          version: json['version'] as String,
          xmlns: json['xmlns'] as String?,
          uniqueIdentifier: json['uniqueIdentifier'] as String,
          metadata: metadata,
          manifest: manifest,
          spine: _decodeSpine(spineJson),
          guide: guide,
        );
}

List<ManifestItem> _decodeManifestItems(final List<Object?> json) => <ManifestItem>[
  for (final item in json) _decodeManifestItem(item as Map<String, Object?>),
];

ManifestItem _decodeManifestItem(final Map<String, Object?> json) => ManifestItem(
  path: json['path'] as String,
  id: json['id'] as String,
  mediaType: json['mediaType'] as String,
  properties: (json['properties'] as List<Object?>?)?.cast<String>() ?? const <String>[],
  mediaOverlay: json['mediaOverlay'] as String?,
);

Spine _decodeSpine(final Map<String, Object?> json) => Spine(
  tocId: json['tocId'] as String?,
  items: (json['items'] as List<Object?>).cast<String>(),
  pageProgressionDirection: PageProgressionDirection.fromName(
    json['pageProgressionDirection'] as String?,
  ),
);

Reference _decodeReference(final Map<String, Object?> json) => Reference(
  href: json['href'] as String,
  title: json['title'] as String,
  type: json['type'] as String,
);

Epub2Metadata _decodeEpub2Metadata(final Map<String, Object?> json) => Epub2Metadata(
  title: json['title'] as String,
  date: json['date'] as String,
  language: json['language'] as String,
  identifiers: (json['identifiers'] as List<Object?>).cast<String>(),
  uniqueIdentifierValue: json['uniqueIdentifierValue'] as String,
  subject: json['subject'] as String?,
  description: json['description'] as String?,
  rights: (json['rights'] as List<Object?>?)?.cast<String>(),
  contributor: json['contributor'] as String?,
  creator: json['creator'] as String?,
  publisher: json['publisher'] as String?,
  coverId: json['coverId'] as String?,
  series: json['series'] as String?,
  seriesIndex: json['seriesIndex'] as String?,
  titleSort: json['titleSort'] as String?,
  authorSort: json['authorSort'] as String?,
  bookProducer: json['bookProducer'] as String?,
);

Epub3Metadata _decodeEpub3Metadata(final Map<String, Object?> json) => Epub3Metadata(
  title: json['title'] as String,
  date: json['date'] as String,
  language: json['language'] as String,
  identifiers: (json['identifiers'] as List<Object?>).cast<String>(),
  uniqueIdentifierValue: json['uniqueIdentifierValue'] as String,
  subject: json['subject'] as String?,
  description: json['description'] as String?,
  rights: (json['rights'] as List<Object?>?)?.cast<String>(),
  contributor: json['contributor'] as String?,
  creator: json['creator'] as String?,
  publisher: json['publisher'] as String?,
  coverId: json['coverId'] as String?,
  series: json['series'] as String?,
  seriesIndex: json['seriesIndex'] as String?,
  titleSort: json['titleSort'] as String?,
  authorSort: json['authorSort'] as String?,
  bookProducer: json['bookProducer'] as String?,
  schemaOrgs: (json['schemaOrgs'] as List<Object?>?)?.cast<String>() ?? const <String>[],
  accessibilitySummaries:
      (json['accessibilitySummaries'] as List<Object?>?)?.cast<String>() ?? const <String>[],
  accessibilityFeatures:
      (json['accessibilityFeatures'] as List<Object?>?)?.cast<String>() ?? const <String>[],
  educationalRole: (json['educationalRole'] as String?) ?? '',
  typicalAgeRange: (json['typicalAgeRange'] as String?) ?? '',
  modified: (json['modified'] as String?) ?? '',
  rendition: (json['rendition'] as String?) ?? '',
  belongsToCollection: (json['belongsToCollection'] as String?) ?? '',
  sourceOf: (json['sourceOf'] as String?) ?? '',
  recordIdentifier: (json['recordIdentifier'] as String?) ?? '',
  mediaDuration: (json['mediaDuration'] as String?) ?? '',
  mediaActiveClass: (json['mediaActiveClass'] as String?) ?? '',
  mediaPlaybackActiveClass: (json['mediaPlaybackActiveClass'] as String?) ?? '',
  narrator: (json['narrator'] as String?) ?? '',
);

/// JSON helper kept next to the wire codec: the worker and the client
/// both travel through strings on the postMessage channel.
Map<String, Object?> decodeJson(final String source) =>
    convert.jsonDecode(source) as Map<String, Object?>;

/// JSON helper kept next to the wire codec.
String encodeJson(final Map<String, Object?> json) => convert.jsonEncode(json);
