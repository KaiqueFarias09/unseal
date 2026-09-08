import 'package:e_livre/src/foundation/entities/book_format.dart';

/// The book family detected from magic bytes.
///
/// Each family is handled by one format module which then refines the
/// concrete [BookFormat] (e.g. `mobi` versus `azw3`).
enum DetectedFormat {
  /// Zip container (EPUB, zipped FB2 or CBZ — refined by content).
  epub,

  /// PalmDB / MOBI family (MOBI 6, KF8 / AZW3, joint files).
  mobiFamily,

  /// FictionBook XML (or zipped FB2).
  fb2,

  /// Comic archive (RAR — CBR).
  comic,

  /// PDF document.
  pdf,

  /// Plain text document.
  txt,

  /// Standalone HTML document.
  html,

  /// AZW4 PalmDB wrapper containing a PDF payload.
  azw4,

  /// 7-Zip comic archive.
  comic7,
}
