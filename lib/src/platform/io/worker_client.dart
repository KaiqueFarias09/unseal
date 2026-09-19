import 'dart:typed_data';

import '../../features/cfi/epub_cfi_resolver.dart';
import '../../features/search/entities/search_mode.dart';
import '../../features/search/entities/search_results.dart';
import '../../foundation/entities/book/book.dart';
import '../../foundation/entities/book_metadata.dart';

/// Native stand-in for the web worker client: runtimes with dart:io
/// parse books on a background isolate and never touch the browser
/// worker.
final class WorkerClient {
  WorkerClient._();

  /// Process-wide client.
  static final WorkerClient instance = WorkerClient._();

  /// Always `false`: native runtimes have no worker to configure.
  bool get isConfigured => false;

  /// No-op: parsing already leaves the caller's thread via the
  /// background isolate.
  void configure(final Uri workerScript) {}

  /// No-op: there is no worker to terminate.
  void dispose() {}

  /// Always `null`: callers parse inline / on the isolate instead.
  Future<Book?> parseInWorker(final Uint8List bytes) => Future<Book?>.value();

  /// Always `null`: callers read metadata inline / on the isolate.
  Future<BookMetadata?> metadataInWorker(final Uint8List bytes) => Future<BookMetadata?>.value();

  /// Always `null`: search keeps running on the calling thread. The background
  /// isolate discards the parsed book, so it has no resident book to search.
  /// Defaults mirror `BookSearch.search` to keep the signature interchangeable
  /// with the web client.
  Future<SearchResults?> searchInWorker(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool isCaseSensitive = false,
    final bool isTolerant = true,
    final int nearChars = 60,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) => Future<SearchResults?>.value();

  /// Always `null`: CFI resolution keeps running on the calling
  /// thread — see [searchInWorker].
  Future<EpubCfiLocation?> resolveCfiInWorker(final String cfi) => Future<EpubCfiLocation?>.value();

  /// Always `null`: CFI building keeps running on the calling thread —
  /// see [searchInWorker].
  Future<String?> buildCfiInWorker({
    required final int contentIndex,
    required final int offsetInText,
  }) => Future<String?>.value();
}
