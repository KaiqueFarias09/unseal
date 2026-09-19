## 1.1.0 - September 19, 2026

Dependency maintenance release. No public API changes.

### Changed

- Upgraded `archive` to `^4.3.0`, `koni_archive` to `^0.9.0`, and `xml` to
  `^7.0.1`, with the corresponding parser migrations.
- Shortened the package description to meet pub.dev conventions.

### Safety and reliability

- ZIP containers with a missing or unreadable central directory now fail with
  `InvalidBookException` instead of decoding to an empty archive.
- ZIP-bomb guards keep bounding decompression during inflation on the
  `archive` 4 streaming API, and explicit directory records in book
  containers keep parsing as empty entries.

## 1.0.0 - September 19, 2026

Initial release of Unseal, a pure-Dart library for parsing ebooks and
producing format-neutral reading data.

### Highlights

- Parses EPUB 2/3, MOBI 6, AZW3/KF8, FB2/FBZ, TXT/TXTZ, HTML/HTMLZ,
  DOCX, ODT, AZW4, CBZ, CBR, CB7, CBC, and PDF.
- Exposes a common `Book` model with metadata, cover data, files, reading
  order, navigation, statistics, and original archive information.
- Provides metadata-only reads, automatic format detection, full-text search,
  locators, EPUB CFI operations, reading progression, portable annotations,
  OPDS parsing, and web-worker support.
- Parses EPUB media-overlay timing, preserves right-to-left progression, reads
  sidecar OPF metadata, and supports MOBI/KF8 navigation, PDF extraction and
  reflow, and comic page ordering.
- Rejects unsupported DRM and encrypted inputs; supported password-protected
  PDFs can be opened with the correct password.

### Safety and reliability

- Uses typed exceptions for empty, malformed, encrypted, and unsupported
  input.
- Bounds ZIP expansion, entry sizes, compression ratios, PDF object nesting,
  and FB2 XML depth to make hostile input fail predictably.
- Rejects symbolic links and unsupported archive compression methods.
- Includes focused regression coverage for malformed and adversarial input on
  the Dart VM and in browsers.
