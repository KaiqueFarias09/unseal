/// The book formats supported by eLivre.
enum BookFormat {
  /// EPUB 2.0 / 3.0 container (zip + OPF package).
  epub,

  /// Mobipocket / Kindle MOBI 6 (legacy).
  mobi,

  /// Kindle KF8 (AZW3).
  azw3,

  /// FictionBook 2.0 (XML) or its zipped variant (FB2.zip).
  fb2,

  /// Comic book zip archive.
  cbz,

  /// Comic book RAR archive (stored and supported RAR 2.9/3.x entries).
  cbr,

  /// PDF (text extraction + reflow; page-faithful rendering stays
  /// with the viewer).
  pdf,

  /// Plain UTF text document.
  txt,

  /// ZIP-wrapped plain text document.
  txtz,

  /// HTML document.
  html,

  /// ZIP-wrapped HTML document.
  htmlz,

  /// Office Open XML Word document.
  docx,

  /// Kindle AZW4 wrapper around a PDF document.
  azw4,

  /// 7-Zip comic archive.
  cb7,

  /// Calibre comic-book collection.
  cbc,

  /// OpenDocument Text document.
  odt,
}
