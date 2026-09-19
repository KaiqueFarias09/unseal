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
- Supports EPUB media overlays, right-to-left progression, sidecar OPF
  metadata, MOBI/KF8 navigation, PDF text extraction and reflow, and comic
  archive page ordering.
- Rejects DRM-protected or encrypted books that cannot be opened safely.

### Safety and reliability

- Uses typed exceptions for empty, malformed, encrypted, and unsupported
  input.
- Bounds ZIP expansion, entry sizes, compression ratios, PDF object nesting,
  and FB2 XML depth to make hostile input fail predictably.
- Rejects symbolic links and unsupported archive compression methods.
- Includes deterministic fuzzing, tracked regression seeds, focused parser
  regressions, and separate Dart VM and browser validation.

### Tooling

- Includes benchmarks for all 16 supported formats, versioned JSON reports,
  baseline comparison, and an opt-in privacy-preserving Calibre library scan.
- Includes a reproducible PDF validation and image-parity harness.
