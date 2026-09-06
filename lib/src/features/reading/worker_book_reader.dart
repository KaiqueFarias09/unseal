import 'package:e_livre/src/features/cfi/epub_cfi_resolver.dart';
import 'package:e_livre/src/features/search/book_search.dart';
import 'package:e_livre/src/platform/web/worker_client.dart'
    if (dart.library.io) 'package:e_livre/src/platform/io/worker_client.dart';

/// Routes web parsing through a dedicated web worker so heavy books
/// never block the UI thread.
///
/// Point it at the compiled worker script once at startup (see
/// `web/e_livre_worker.dart` in the package sources for the entry
/// point and its build command):
///
/// ```dart
/// WorkerBookReader.configure(Uri.parse('e_livre_worker.js'));
/// ```
///
/// From then on `BookReader.openFromBytes` and
/// `BookReader.readMetadataFromBytes` run inside the worker. Books
/// that fail to parse throw exactly like the inline path; if the
/// worker itself is unavailable (script unreachable, workers blocked
/// by the host), parsing silently falls back to the main thread.
///
/// Native runtimes ignore the configuration: parsing already runs on
/// a background isolate there.
abstract final class WorkerBookReader {
  /// Points the reader at a compiled [workerScript]. Must be
  /// same-origin unless served with proper CORS worker headers.
  static void configure(final Uri workerScript) {
    WorkerClient.instance.configure(workerScript);
  }

  /// Whether a worker script is configured and the worker has not
  /// broken; parse requests still fall back to inline when `false`.
  static bool get isConfigured => WorkerClient.instance.isConfigured;

  /// Terminates the worker and forgets the configuration.
  static void dispose() {
    WorkerClient.instance.dispose();
  }

  /// Worker-backed fast path for `book.search`: searches the book kept
  /// resident from the last `openFromBytes` inside the worker, with
  /// the [BookSearch.search] defaults. Returns `null` when the worker
  /// or its resident book is unavailable — run `book.search` inline as
  /// the fallback.
  static Future<SearchResults?> searchInWorker(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool caseSensitive = false,
    final bool tolerant = true,
    final int nearChars = 60,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) => WorkerClient.instance.searchInWorker(
    query,
    mode: mode,
    caseSensitive: caseSensitive,
    tolerant: tolerant,
    nearChars: nearChars,
    contextChars: contextChars,
    maxMatches: maxMatches,
  );

  /// Worker-backed fast path for `EpubCfiResolver.resolveCfi`:
  /// resolves [cfi] against the resident book inside the worker.
  /// Returns `null` when the worker or its resident book is
  /// unavailable, or when the CFI is malformed or resolves nowhere —
  /// resolve inline as the fallback.
  static Future<EpubCfiLocation?> resolveCfiInWorker(final String cfi) =>
      WorkerClient.instance.resolveCfiInWorker(cfi);

  /// Worker-backed fast path for `EpubCfiResolver.buildEpubCfi`:
  /// builds a book-level CFI for a reading position in the resident
  /// book inside the worker. Returns `null` when the worker or its
  /// resident book is unavailable — build inline as the fallback.
  static Future<String?> buildCfiInWorker({
    required final int contentIndex,
    required final int offsetInText,
  }) => WorkerClient.instance.buildCfiInWorker(
    contentIndex: contentIndex,
    offsetInText: offsetInText,
  );
}
