import '../../../foundation/entities/book_format.dart';

/// The book family detected from magic bytes.
///
/// Each family is handled by one format module which then refines the concrete [BookFormat] (e.g.
/// `mobi` versus `azw3`).
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

  /// DjVu single-page or bundled document.
  djvu,

  /// Plain text document.
  txt,

  /// Rich Text Format document.
  rtf,

  /// PalmDOC text in a Palm Database.
  palmdoc,

  /// Unencrypted eReader PDB publication.
  ereader,

  /// Plucker pages stored in a Palm Database.
  plucker,

  /// Standalone HTML document.
  html,

  /// AZW4 PalmDB wrapper containing a PDF payload.
  azw4,

  /// 7-Zip comic archive.
  comic7,

  /// Microsoft Compiled HTML Help (ITSF/CHM).
  chm,
}
