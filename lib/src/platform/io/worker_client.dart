import 'dart:typed_data';

import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';

/// Native runtimes parse books in a background isolate and do not need the
/// browser worker implementation.
final class WorkerClient {
  WorkerClient._();

  static final WorkerClient instance = WorkerClient._();

  bool get isConfigured => false;

  void configure(final Uri workerScript) {}

  void dispose() {}

  Future<Book?> parseInWorker(final Uint8List bytes) => Future<Book?>.value();

  Future<BookMetadata?> metadataInWorker(final Uint8List bytes) =>
      Future<BookMetadata?>.value();
}
