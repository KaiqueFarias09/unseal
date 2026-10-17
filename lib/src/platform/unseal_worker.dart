import 'dart:typed_data';

import '../features/alto/bind_alto_snapshot.dart';
import '../features/cfi/epub_cfi_resolver.dart';
import '../features/djvu/djvu_page_structure.dart';
import '../features/search/book_search.dart';
import '../features/search/entities/search_mode.dart';
import '../features/search/entities/search_results.dart';
import '../foundation/text/publication_revision.dart';
import 'web/worker_client.dart' if (dart.library.io) 'io/worker_client.dart';

/// Routes web parsing through a dedicated web worker so heavy books
/// never block the UI thread.
///
/// Point it at the compiled worker script once at startup (see
/// `web/unseal_worker.dart` in the package sources for the entry
/// point and its build command):
///
/// ```dart
/// UnsealWorker.configure(Uri.parse('unseal_worker.js'));
/// ```
///
/// From then on `Unseal.read` and `Unseal.readMetadata` run inside the
/// worker. Books that fail to parse throw exactly like the inline path; if the
/// worker itself is unavailable (script unreachable, workers blocked
/// by the host), parsing silently falls back to the main thread.
///
/// Native runtimes ignore the configuration: parsing already runs on
/// a background isolate there.
// This public facade intentionally keeps worker configuration separate from
// the normal [Unseal] entry points.
// ignore: avoid_classes_with_only_static_members
abstract final class UnsealWorker {
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
  /// resident from the last `Unseal.read` inside the worker, with
  /// the [BookSearch.search] defaults. Returns `null` when the worker
  /// or its resident book is unavailable — run `book.search` inline as
  /// the fallback.
  static Future<SearchResults?> searchInWorker(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool isCaseSensitive = false,
    final bool isTolerant = true,
    final int nearChars = 60,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) {
    return WorkerClient.instance.searchInWorker(
      query,
      mode: mode,
      isCaseSensitive: isCaseSensitive,
      isTolerant: isTolerant,
      nearChars: nearChars,
      contextChars: contextChars,
      maxMatches: maxMatches,
    );
  }

  /// Worker-backed fast path for `DjvuBook.pageStructureAt`: reads the
  /// resident DjVu book page's spatial structure inside the worker.
  /// Returns `null` when the worker or its resident book is
  /// unavailable, the resident book is not DjVu, or the page has no
  /// hidden-text chunk.
  static Future<DjvuPageStructure?> spatialDjvuPageInWorker(final int pageIndex) {
    return WorkerClient.instance.spatialDjvuPageInWorker(pageIndex);
  }

  /// Worker-backed fast path for `bindAltoToSnapshot`: parses [altoBytes]
  /// inside the worker and binds them onto the resident DjVu page's
  /// hidden-text snapshot. Returns `null` when the worker or its
  /// resident book is unavailable — bind inline as the fallback.
  static Future<AltoBoundSpatialText?> bindAltoInWorker({
    required final Uint8List altoBytes,
    required final int pageIndex,
    required final PublicationRevision identity,
  }) {
    return WorkerClient.instance.bindAltoInWorker(
      altoBytes: altoBytes,
      pageIndex: pageIndex,
      identity: identity,
    );
  }

  /// Worker-backed fast path for `EpubCfiResolver.resolveCfi`:
  /// resolves [cfi] against the resident book inside the worker.
  /// Returns `null` when the worker or its resident book is
  /// unavailable, or when the CFI is malformed or resolves nowhere —
  /// resolve inline as the fallback.
  static Future<EpubCfiLocation?> resolveCfiInWorker(final String cfi) {
    return WorkerClient.instance.resolveCfiInWorker(cfi);
  }

  /// Worker-backed fast path for `EpubCfiResolver.buildEpubCfi`:
  /// builds a book-level CFI for a reading position in the resident
  /// book inside the worker. Returns `null` when the worker or its
  /// resident book is unavailable — build inline as the fallback.
  static Future<String?> buildCfiInWorker({
    required final int contentIndex,
    required final int offsetInText,
  }) {
    return WorkerClient.instance.buildCfiInWorker(
      contentIndex: contentIndex,
      offsetInText: offsetInText,
    );
  }
}
