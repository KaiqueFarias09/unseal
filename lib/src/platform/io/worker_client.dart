import 'dart:typed_data';

import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';

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
}
