import 'dart:typed_data';

import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

import 'worker_client.dart';

/// Parses in the configured web worker when available, keeping heavy
/// books off the UI thread; otherwise runs on the main thread (the
/// web has no isolates).
Future<Book> parseBookInBackground(final Book Function() parse, final Uint8List bytes) async {
  final parsed = await WorkerClient.instance.parseInWorker(bytes);

  return parsed ?? parse();
}

/// Reads metadata in the configured web worker when available;
/// otherwise runs on the main thread.
Future<BookMetadata> readMetadataInBackground(
  final BookMetadata Function() read,
  final Uint8List bytes,
) async {
  final metadata = await WorkerClient.instance.metadataInWorker(bytes);

  return metadata ?? read();
}
