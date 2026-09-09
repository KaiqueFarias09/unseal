import 'dart:isolate';
import 'dart:typed_data';

import '../../foundation/entities/entities.dart';

/// Runs book parsing away from the caller on isolate-supporting runtimes.
Future<Book> parseBookInBackground(final Book Function() parse, final Uint8List bytes) =>
    _run(parse);

/// Runs metadata extraction away from the caller on isolate-supporting runtimes.
Future<BookMetadata> readMetadataInBackground(
  final BookMetadata Function() read,
  final Uint8List bytes,
) => _run(read);

/// Runs [action] away from the caller, falling back to the current
/// isolate when the runtime refuses to spawn one.
Future<T> _run<T>(final T Function() action) async {
  try {
    return await Isolate.run(action);
  } on UnsupportedError {
    return action();
  }
}
