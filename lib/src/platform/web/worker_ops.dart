import 'dart:typed_data';

import '../../features/cfi/epub_cfi.dart';
import '../../features/cfi/epub_cfi_resolver.dart';
import '../../features/epub/entities/book/book.dart';
import '../../features/mobi/header/pdb_header.dart';
import '../../features/pdf/entities/pdf_book.dart';
import '../../features/progressive/session_engine.dart';
import '../../features/progressive/session_policy.dart';
import '../../features/reading/book_dispatch.dart';
import '../../features/search/book_search.dart';
import '../../features/search/entities/search_mode.dart';
import '../../features/search/index/indexed_query_mode.dart';
import '../../features/search/index/search_index_identity.dart';
import '../../foundation/entities/book/book.dart';
import '../../foundation/entities/book_format.dart';
import '../../foundation/exceptions/unseal_exception.dart';

import 'book_wire.dart';
import 'wire/book_components_wire.dart';
import 'wire/pdf_structure_wire.dart';

/// Runs one worker op against the request [bytes], the
/// [residentBook] left behind by the last successful parse and the
/// [residentSession] selected by the request's session ID, producing
/// the reply the worker shell posts back: the reply kind, its JSON half,
/// the blob list the JSON references and the session the shell must
/// keep resident (the freshly opened engine of a `sessionOpen`, null
/// for every other op).
///
/// Pure and VM-testable: no browser types, no message channel — the
/// shell in `web/unseal_worker.dart` only unwraps the incoming
/// message, calls this and wraps the result.
///
/// `parse` / `metadata` / `sessionOpen` read [bytes]; `sessionOpen`
/// also reads its policy payload. `search`, `cfiResolve`, `cfiBuild`
/// and later `session*` ops read [payload] (see the `wireKey*` keys)
/// and act on the resident book or selected session, throwing
/// [UnsealException] (the session ops [SessionClosedException]) when
/// nothing is resident or the state cannot serve the op. Unknown ops throw [UnsealException]; a
/// bad [SearchMode.regex] pattern or proximity query surfaces as
/// [FormatException] untouched, so the error reply keeps the exception
/// type.
({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session}) runWorkerOp({
  required final String op,
  final Map<String, Object?>? payload,
  final Uint8List? bytes,
  final Book? residentBook,
  final SessionEngine? residentSession,
}) {
  switch (op) {
    case workerOpParse:
      final book = BookDispatch.parseBook(bytes!);
      Uint8List? record0;
      String? ident;
      if (book.format == BookFormat.mobi || book.format == BookFormat.azw3) {
        final pdb = PdbHeader.parse(bytes);
        record0 = mobiWireRecord0(bytes);
        ident = pdb.ident;
      }
      final (json, blobs) = encodeBookWire(book, mobiRecord0: record0, mobiIdent: ident);

      return (kind: wireReplyBook, json: json, blobs: blobs, session: null);
    case workerOpMetadata:
      final (json, blobs) = encodeMetadataWire(BookDispatch.readMetadataSync(bytes!));

      return (kind: wireReplyMetadata, json: json, blobs: blobs, session: null);
    case workerOpSearch:
      return _search(payload!, residentBook);
    case workerOpCfiResolve:
      return _cfiResolve(payload!, residentBook);
    case workerOpCfiBuild:
      return _cfiBuild(payload!, residentBook);
    case workerOpSessionOpen:
      return _sessionOpen(bytes!, payload, residentSession);
    case workerOpSessionResource:
      return _sessionResource(payload!, residentSession);
    case workerOpSessionResources:
      return _sessionResources(payload!, residentSession);
    case workerOpSessionRange:
      return _sessionRange(payload!, residentSession);
    case workerOpSessionSource:
      return _sessionSource(payload!, residentSession);
    case workerOpSessionPdfLines:
      return _sessionPdfLines(payload!, residentSession);
    case workerOpSessionPdfStructure:
      return _sessionPdfStructure(payload!, residentSession);
    case workerOpSessionText:
      return _sessionText(payload!, residentSession);
    case workerOpSessionSearch:
      return _sessionSearch(payload!, residentSession);
    case workerOpSessionSearchIndexEnsure:
      return _sessionSearchIndexEnsure(payload!, residentSession);
    case workerOpSessionSearchIndexQuery:
      return _sessionSearchIndexQuery(payload!, residentSession);
    case workerOpSessionSearchIndexExport:
      return _sessionSearchIndexExport(residentSession);
    case workerOpSessionSearchIndexImport:
      return _sessionSearchIndexImport(payload!, residentSession);
    case workerOpSessionSearchIndexDrop:
      return _sessionSearchIndexDrop(residentSession);
    case workerOpSessionProgression:
      return _sessionProgression(residentSession);
    case workerOpSessionStatistics:
      return _sessionStatistics(residentSession);
    case workerOpSessionCfiResolve:
      return _sessionCfiResolve(payload!, residentSession);
    case workerOpSessionCfiBuild:
      return _sessionCfiBuild(payload!, residentSession);
    case workerOpSessionDispose:
      residentSession?.close();

      return (
        kind: wireReplySessionDispose,
        json: const <String, Object?>{},
        blobs: const <Object>[],
        session: null,
      );
    default:
      throw UnsealException('Worker request holds an unknown op: $op');
  }
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session}) _search(
  final Map<String, Object?> payload,
  final Book? residentBook,
) {
  final results = _residentFor(residentBook).search(
    payload[wireKeyQuery] as String,
    mode: SearchMode.values.byName(payload[wireKeyMode] as String),
    isCaseSensitive: payload[wireKeyCaseSensitive] as bool,
    isTolerant: payload[wireKeyTolerant] as bool,
    nearChars: payload[wireKeyNearChars] as int,
    contextChars: payload[wireKeyContextChars] as int,
    maxMatches: payload[wireKeyMaxMatches] as int,
  );

  return (
    kind: wireReplySearch,
    json: encodeSearchResultsWire(results),
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session}) _cfiResolve(
  final Map<String, Object?> payload,
  final Book? residentBook,
) {
  final book = _residentEpubFor(residentBook);
  final cfi = EpubCfi.tryParse(payload[wireKeyCfi] as String);
  final location = cfi == null ? null : book.resolveCfi(cfi);

  return (
    kind: wireReplyCfiLocation,
    json: <String, Object?>{wireKeyLocation: encodeCfiLocationWire(location)},
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session}) _cfiBuild(
  final Map<String, Object?> payload,
  final Book? residentBook,
) {
  final cfi = _residentEpubFor(residentBook).buildEpubCfi(
    contentIndex: payload[wireKeyContentIndex] as int,
    offsetInText: payload[wireKeyOffsetInText] as int,
  );

  return (
    kind: wireReplyCfi,
    json: <String, Object?>{wireKeyCfi: cfi},
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session}) _sessionOpen(
  final Uint8List bytes,
  final Map<String, Object?>? payload,
  final SessionEngine? residentSession,
) {
  final defaults = const SessionPolicy();
  final session = SessionEngine.openBytes(
    bytes,
    password: (payload?[wireKeyPassword] as String?) ?? '',
    policy: SessionPolicy(
      cacheBytes: (payload?[wireKeyCacheBytes] as int?) ?? defaults.cacheBytes,
      coverMaxBytes: (payload?[wireKeyCoverMaxBytes] as int?) ?? defaults.coverMaxBytes,
      rangeMaxBytes: (payload?[wireKeyRangeMaxBytes] as int?) ?? defaults.rangeMaxBytes,
    ),
  );
  // A fresh open replaces only the session selected by this request;
  // closing only after the new container parsed keeps a failed open
  // from destroying the session that was still serving.
  residentSession?.close();

  final (json, blobs) = encodeSessionHeaderWire(session.book);
  json[wireKeyProgressive] = true;
  json[wireKeyByteLength] = session.byteLength;

  return (kind: wireReplySessionOpen, json: json, blobs: blobs, session: session);
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionResource(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final bytes = _sessionFor(residentSession).resource(payload[wireKeyPath] as String);
  final blobs = <Object>[];

  return (
    kind: wireReplySessionResource,
    json: <String, Object?>{wireKeyBlobIndex: bytes == null ? null : pushWireBlob(blobs, bytes)},
    blobs: blobs,
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionResources(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final session = _sessionFor(residentSession);
  final blobs = <Object>[];
  final found = <String>[];
  for (final path in (payload[wireKeyPaths] as List<Object?>).cast<String>()) {
    if (session.resource(path) case final Uint8List bytes) {
      found.add(path);
      pushWireBlob(blobs, bytes);
    }
  }

  return (
    kind: wireReplySessionResources,
    json: <String, Object?>{wireKeyPaths: found},
    blobs: blobs,
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionRange(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final slice = _sessionFor(
    residentSession,
  ).bytesRange(payload[wireKeyOffset] as int, payload[wireKeyCount] as int);
  final blobs = <Object>[];

  return (
    kind: wireReplySessionRange,
    json: <String, Object?>{wireKeyBlobIndex: pushWireBlob(blobs, slice)},
    blobs: blobs,
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionSource(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final text = _sessionFor(residentSession).documentSource(payload[wireKeyPath] as String);
  final blobs = <Object>[];

  return (
    kind: wireReplySessionSource,
    json: <String, Object?>{wireKeyBlobIndex: text == null ? null : pushWireBlob(blobs, text)},
    blobs: blobs,
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionPdfLines(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final session = _sessionFor(residentSession);
  final pageIndex = payload[wireKeyPageIndex] as int;
  final page = session.loadPdfPageLines(pageIndex);
  final geometry = (session.book as PdfBook).pages[pageIndex];
  final json = <String, Object?>{
    wireKeyPage: encodePdfPageLinesWire(
      page,
      pageWidth: geometry.width,
      pageHeight: geometry.height,
    ),
  };

  return (kind: wireReplySessionPdfLines, json: json, blobs: const <Object>[], session: null);
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionPdfStructure(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final session = _sessionFor(residentSession);
  final pageIndex = payload[wireKeyPageIndex] as int;
  final structure = session.loadPdfPageStructure(pageIndex);
  final json = <String, Object?>{wireKeyStructure: encodePdfPageStructureWire(structure)};

  return (kind: wireReplySessionPdfStructure, json: json, blobs: const <Object>[], session: null);
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session}) _sessionText(
  final Map<String, Object?> payload,
  final SessionEngine? residentSession,
) {
  final text = _sessionFor(residentSession).documentText(payload[wireKeyPath] as String);
  final blobs = <Object>[];

  return (
    kind: wireReplySessionText,
    json: <String, Object?>{wireKeyBlobIndex: text == null ? null : pushWireBlob(blobs, text)},
    blobs: blobs,
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionSearch(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final results = _sessionFor(residentSession).search(
    payload[wireKeyQuery] as String,
    mode: SearchMode.values.byName(payload[wireKeyMode] as String),
    isCaseSensitive: payload[wireKeyCaseSensitive] as bool,
    isTolerant: payload[wireKeyTolerant] as bool,
    nearChars: payload[wireKeyNearChars] as int,
    contextChars: payload[wireKeyContextChars] as int,
    maxMatches: payload[wireKeyMaxMatches] as int,
  );

  return (
    kind: wireReplySessionSearch,
    json: encodeSearchResultsWire(results),
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionSearchIndexEnsure(
  final Map<String, Object?> payload,
  final SessionEngine? residentSession,
) {
  final coverage = _sessionFor(residentSession).searchIndexEnsure(
    payload[wireKeyMaxSections] as int,
    SearchIndexIdentity.fromWire(payload[wireKeyIndexIdentity]),
  );

  return (
    kind: wireReplySessionSearchIndexCoverage,
    json: coverage,
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionSearchIndexQuery(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final results = _sessionFor(residentSession).searchIndexQuery(
    payload[wireKeyQuery] as String,
    mode: IndexedQueryMode.values.byName(payload[wireKeyMode] as String),
    maxMatches: payload[wireKeyMaxMatches] as int?,
    maxExpansions: payload[wireKeyMaxExpansions] as int?,
    contextChars: payload[wireKeyContextChars] as int,
  );

  return (
    kind: wireReplySessionSearchIndexResults,
    json: results,
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionSearchIndexExport(final SessionEngine? residentSession) {
  final payload = _sessionFor(residentSession).searchIndexExport();

  return (
    kind: wireReplySessionSearchIndexPayload,
    json: payload,
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionSearchIndexImport(
  final Map<String, Object?> payload,
  final SessionEngine? residentSession,
) {
  final coverage = _sessionFor(residentSession).searchIndexImport(
    (payload[wireKeyIndexPayload]! as Map).cast<String, Object?>(),
    SearchIndexIdentity.fromWire(payload[wireKeyIndexIdentity]),
  );

  return (
    kind: wireReplySessionSearchIndexCoverage,
    json: coverage,
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionSearchIndexDrop(final SessionEngine? residentSession) {
  _sessionFor(residentSession).searchIndexDrop();

  return (
    kind: wireReplySessionSearchIndexDrop,
    json: const <String, Object?>{},
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionProgression(final SessionEngine? residentSession) {
  final progression = _sessionFor(residentSession).computeProgression();

  return (
    kind: wireReplySessionProgression,
    json: <String, Object?>{
      wireKeySectionLengths: progression.sectionLengths,
      wireKeyTotalCharacters: progression.totalCharacters,
    },
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionStatistics(final SessionEngine? residentSession) {
  final statistics = _sessionFor(residentSession).computeStatistics();

  return (
    kind: wireReplySessionStatistics,
    json: <String, Object?>{
      wireKeyWordCount: statistics.wordCount,
      wireKeyCharacterCount: statistics.characterCount,
    },
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionCfiResolve(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  // The engine owns CFI parsing, like the inline resolver: malformed
  // and unresolving CFIs come back as JSON null.
  final location = _sessionFor(residentSession).resolveCfi(payload[wireKeyCfi] as String);

  return (
    kind: wireReplySessionCfiLocation,
    json: <String, Object?>{wireKeyLocation: encodeCfiLocationWire(location)},
    blobs: const <Object>[],
    session: null,
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
_sessionCfiBuild(final Map<String, Object?> payload, final SessionEngine? residentSession) {
  final cfi = _sessionFor(residentSession).buildCfi(
    contentIndex: payload[wireKeyContentIndex] as int,
    offsetInText: payload[wireKeyOffsetInText] as int,
  );

  return (
    kind: wireReplySessionCfi,
    json: <String, Object?>{wireKeyCfi: cfi},
    blobs: const <Object>[],
    session: null,
  );
}

/// The book the stateful ops run against, rejecting the request when
/// nothing was parsed yet.
Book _residentFor(final Book? residentBook) {
  if (residentBook == null) {
    throw const UnsealException('No resident book: parse one before running stateful ops.');
  }

  return residentBook;
}

/// The resident book as an [EpubBook]; CFI ops have no meaning for the
/// other formats.
EpubBook _residentEpubFor(final Book? residentBook) {
  final book = _residentFor(residentBook);
  if (book is! EpubBook) {
    throw UnsealException('CFI ops need a resident EPUB book, got ${book.format.name}.');
  }

  return book;
}

/// The engine the session ops run against. A worker holds at most one
/// session; asking for session results without one is the same
/// contract as asking them of a closed session.
SessionEngine _sessionFor(final SessionEngine? residentSession) {
  if (residentSession == null) throw const SessionClosedException();

  return residentSession;
}
