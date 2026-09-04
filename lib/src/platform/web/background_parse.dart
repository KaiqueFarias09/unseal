import 'dart:typed_data';

import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

/// Parses on the current isolate: the web has no isolates, so heavy
/// books block the UI thread until a web worker is configured.
Future<Book> parseBookInBackground(
  final Book Function() parse,
  final Uint8List bytes,
) => Future<Book>.value(parse());

/// Reads metadata on the current isolate (the web has no isolates).
Future<BookMetadata> readMetadataInBackground(
  final BookMetadata Function() read,
  final Uint8List bytes,
) => Future<BookMetadata>.value(read());
