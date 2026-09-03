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

  /// Comic book RAR archive (stored entries only).
  cbr,
}
