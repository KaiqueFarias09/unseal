import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../../cfi/epub_cfi_resolver.dart';
import '../../reading/book_progression.dart';
import '../../search/entities/search_mode.dart';
import '../../search/entities/search_results.dart';
import '../session_engine.dart';

/// The delivery layer behind the public `BookSession`: one session's ops
/// its resident engine.
abstract interface class SessionTransport {
  /// Inflated bytes of one container entry, or null when missing.
  Future<Uint8List?> resource(final String path);

  /// Inflated bytes of several entries; missing paths are omitted.
  Future<Map<String, Uint8List>> resources(final Set<String> paths);

  /// Canonical document text of a content document, or null when
  /// missing.
  Future<String?> documentText(final String path);

  /// Raw decoded source of a content document (markup included), or
  /// null when missing.
  Future<String?> documentSource(final String path);

  /// Whole-book search with the `BookSearch.search` contract.
  Future<SearchResults> search(
    final String query, {
    required final SearchMode mode,
    required final bool isCaseSensitive,
    required final bool isTolerant,
    required final int nearChars,
    required final int contextChars,
    required final int maxMatches,
  });

  /// Whole-book progression, measured section by section.
  Future<BookProgression> computeProgression();

  /// Whole-book statistics over canonical plain text.
  Future<BookStatistics> computeStatistics();

  /// CFI resolution against the resident book, or null when the CFI is
  /// malformed or resolves nowhere.
  Future<EpubCfiLocation?> resolveCfi(final String cfi);

  /// Book-level CFI construction from a reading position.
  Future<String> buildCfi({required final int contentIndex, required final int offsetInText});

  /// Fails every in-flight request with
  /// `SessionCancelledException`.
  void cancelPending();

  /// Ends the session; pending and subsequent requests complete with
  /// `SessionClosedException`.
  void dispose();
}

/// Transport that runs the engine in the caller: the fallback when no
/// isolate or Web Worker is available, and the reference behavior the
/// remote transports must match.
final class InlineSessionTransport implements SessionTransport {
  /// Wraps the engine this transport drives.
  InlineSessionTransport(this._engine);

  final SessionEngine _engine;

  @override
  Future<Uint8List?> resource(final String path) async => _engine.resource(path);

  @override
  Future<Map<String, Uint8List>> resources(final Set<String> paths) async {
    final result = <String, Uint8List>{};
    for (final path in paths) {
      final bytes = _engine.resource(path);
      if (bytes != null) result[path] = bytes;
    }

    return result;
  }

  @override
  Future<String?> documentText(final String path) async => _engine.documentText(path);

  @override
  Future<String?> documentSource(final String path) async => _engine.documentSource(path);

  @override
  Future<SearchResults> search(
    final String query, {
    required final SearchMode mode,
    required final bool isCaseSensitive,
    required final bool isTolerant,
    required final int nearChars,
    required final int contextChars,
    required final int maxMatches,
  }) async => _engine.search(
    query,
    mode: mode,
    isCaseSensitive: isCaseSensitive,
    isTolerant: isTolerant,
    nearChars: nearChars,
    contextChars: contextChars,
    maxMatches: maxMatches,
  );

  @override
  Future<BookProgression> computeProgression() async => _engine.computeProgression();

  @override
  Future<BookStatistics> computeStatistics() async => _engine.computeStatistics();

  @override
  Future<EpubCfiLocation?> resolveCfi(final String cfi) async => _engine.resolveCfi(cfi);

  @override
  Future<String> buildCfi({required final int contentIndex, required final int offsetInText}) =>
      Future<String>.value(
        _engine.buildCfi(contentIndex: contentIndex, offsetInText: offsetInText),
      );

  @override
  void cancelPending() {
    // Engine ops run synchronously here: nothing can be in flight.
  }

  @override
  void dispose() => _engine.close();
}
