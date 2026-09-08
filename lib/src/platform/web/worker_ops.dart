import 'dart:typed_data';

import 'package:e_livre/src/features/cfi/epub_cfi.dart';
import 'package:e_livre/src/features/cfi/epub_cfi_resolver.dart';
import 'package:e_livre/src/features/epub/entities/book/book.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/features/reading/book_reader.dart';
import 'package:e_livre/src/features/search/book_search.dart';
import 'package:e_livre/src/features/search/entities/search_mode.dart';
import 'package:e_livre/src/foundation/entities/book/book.dart';
import 'package:e_livre/src/foundation/entities/book_format.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';

import 'book_wire.dart';

/// Runs one worker op against the request [bytes] and the
/// [residentBook] left behind by the last successful parse, producing
/// the reply the worker shell posts back: the reply kind, its JSON
/// half and the blob list the JSON references (empty for every op but
/// `parse`).
///
/// Pure and VM-testable: no browser types, no message channel — the
/// shell in `web/e_livre_worker.dart` only unwraps the incoming
/// message, calls this and wraps the result.
///
/// `parse` / `metadata` read [bytes]; `search`, `cfiResolve` and
/// `cfiBuild` read [payload] (see the `wireKey*` payload keys) and act
/// on [residentBook], throwing [ELivreException] when no book is
/// resident or the resident book cannot serve the op. Unknown ops
/// throw [ELivreException]; a bad [SearchMode.regex] pattern or
/// proximity query surfaces as [FormatException] untouched, so the
/// error reply keeps the exception type.
({String kind, Map<String, Object?> json, List<Object> blobs}) runWorkerOp({
  required final String op,
  final Map<String, Object?>? payload,
  final Uint8List? bytes,
  final Book? residentBook,
}) {
  switch (op) {
    case workerOpParse:
      final book = BookReader.parseBook(bytes!);
      Uint8List? record0;
      String? ident;
      if (book.format == BookFormat.mobi || book.format == BookFormat.azw3) {
        final pdb = PdbHeader.parse(bytes);
        record0 = mobiWireRecord0(bytes);
        ident = pdb.ident;
      }
      final (json, blobs) = encodeBookWire(book, mobiRecord0: record0, mobiIdent: ident);

      return (kind: wireReplyBook, json: json, blobs: blobs);
    case workerOpMetadata:
      final (json, blobs) = encodeMetadataWire(BookReader.readMetadataSync(bytes!));

      return (kind: wireReplyMetadata, json: json, blobs: blobs);
    case workerOpSearch:
      return _search(payload!, residentBook);
    case workerOpCfiResolve:
      return _cfiResolve(payload!, residentBook);
    case workerOpCfiBuild:
      return _cfiBuild(payload!, residentBook);
    default:
      throw ELivreException('Worker request holds an unknown op: $op');
  }
}

({String kind, Map<String, Object?> json, List<Object> blobs}) _search(
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

  return (kind: wireReplySearch, json: encodeSearchResultsWire(results), blobs: const <Object>[]);
}

({String kind, Map<String, Object?> json, List<Object> blobs}) _cfiResolve(
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
  );
}

({String kind, Map<String, Object?> json, List<Object> blobs}) _cfiBuild(
  final Map<String, Object?> payload,
  final Book? residentBook,
) {
  final cfi = _residentEpubFor(residentBook).buildEpubCfi(
    contentIndex: payload[wireKeyContentIndex] as int,
    offsetInText: payload[wireKeyOffsetInText] as int,
  );

  return (kind: wireReplyCfi, json: <String, Object?>{wireKeyCfi: cfi}, blobs: const <Object>[]);
}

/// The book the stateful ops run against, rejecting the request when
/// nothing was parsed yet.
Book _residentFor(final Book? residentBook) {
  if (residentBook == null) {
    throw const ELivreException('No resident book: parse one before running stateful ops.');
  }

  return residentBook;
}

/// The resident book as an [EpubBook]; CFI ops have no meaning for the
/// other formats.
EpubBook _residentEpubFor(final Book? residentBook) {
  final book = _residentFor(residentBook);
  if (book is! EpubBook) {
    throw ELivreException('CFI ops need a resident EPUB book, got ${book.format.name}.');
  }

  return book;
}
