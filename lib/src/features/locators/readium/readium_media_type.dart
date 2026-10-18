/// Media-type derivation shared by the Readium conversions and position
/// builder: EPUB books use the manifest's declared type; other books use
/// the declared extension fallback table (`doc/readium-locators.md`).
library;

import '../../../foundation/entities/entities.dart';
import '../../epub/entities/entities.dart';

/// The media type of the reading-order resource at [sectionIndex].
String readiumMediaTypeOf(final Book book, final int sectionIndex) {
  final order = book.readingOrder;
  if (sectionIndex < 0 || sectionIndex >= order.length) {
    return 'application/octet-stream';
  }
  final path = order[sectionIndex].name;

  final epub = book is EpubBook ? book : null;
  if (epub != null) {
    for (final item in epub.package.manifest.items) {
      if (item.path == path) return item.mediaType;
    }
  }
  for (final file in book.files.html) {
    if (file.path == path) return mediaTypeForName(file.name);
  }

  return mediaTypeForName(path);
}

/// Media type for a page image resource name.
String mediaTypeForName(final String name) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'xhtml' || 'xht' => 'application/xhtml+xml',
    'html' || 'htm' => 'text/html',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    _ => 'application/octet-stream',
  };
}
