## Unreleased

### Added

- The common text contract for cross-mode positions (foundation): immutable
  `CanonicalTextSnapshot` bound to a `PublicationRevision` (namespaced,
  evidence-qualified source revision), a `SectionOccurrence` (zero-based
  section index, exact parser path, reading-order digest), and a `TextProfile`
  (algorithm, options, extraction-plan revision). `RevisionDigest` computes
  `sha256:` revisions over little-endian UTF-16 code units — text, ordered
  reading-order arrays, and text profiles — with identical bytes and hashes
  on the VM and in Chrome (pinned vectors run in both). `CanonicalTextRange`
  binds inclusive-start/exclusive-end UTF-16 bounds to a snapshot;
  `CanonicalTextCodec` is the single encoder/decoder for snapshots and
  ranges, revalidating every digest on import, refusing non-exportable
  identities explicitly, and normalizing hostile payloads to
  `CanonicalTextCodecException` while confirmed identity mismatches surface
  as `IncompatibleRevisionException`.
- PDF structured layout with stable positions: `PdfPageStructure` per page
  (eager `buildPdfPageStructure`, session `loadPdfPageStructure`, and the
  `sessionPdfStructure` worker op) exposes words derived from real glyph
  advances (rotated words keep their advance direction; ligatures expand
  through ToUnicode at a single advance), Docstrum-adapted text lines and
  blocks, recursive XY-cut reading order with column regions and
  header/footer roles, and Tabula-ported table detection — ruled lattices
  (`spreadsheet`), vertical rulings plus text rows (`basic`), and the
  whitespace-aligned fallback (`aligned-columns`), with typed refusals
  (`rotated-rows`, `text-spans-grid`, `too-few-cells`) instead of silent
  misses. `PdfSourceRange` anchors live in the per-page source-line space
  and stay stable across reopenings and full ↔ session mode switches;
  `mapSourceRange` resolves them into any canonical text as
  `mapped`/`ambiguous`/`missing`/`unsupported` with explicit reasons. The
  canonical profile binds the reflow plan revision (`pdf.reflow`, scope
  `document` or `session-sample`), so the two modes never share a text
  revision; snapshots bound to them refuse cross-mode reuse through
  `CanonicalTextCodec` while anchors keep mapping. `PdfPageGeometry`
  carries the cropped, rotated page space and the invertible affine back
  to PDF user space. Ported from PdfPig `3452b9fb` (Apache-2.0) and
  tabula-java `2cdf3b4f` (MIT) at the pinned revisions; the PdfPig dump
  oracle and comparator live in `tool/pdf_layout_compare.dart`.

## 1.2.0 - October 16, 2026

### Added

- EPUB fixed-layout modeling: declared page viewports
  (`EpubBook.contentViewports`, `viewportForSpineIndex`) read from XHTML
  `<meta name="viewport">` declarations and standalone SVG geometry, spine
  `linear="no"` items (`nonLinearSpinePaths`, `spineItemIsLinear`), and
  effective per-spine-index rendition helpers (`layoutForSpineIndex`,
  `orientationForSpineIndex`, `spreadForSpineIndex`,
  `pageSpreadForSpineIndex`) on `EpubBook`.
- Standalone SVG content documents join the EPUB reading order and search as
  text content documents instead of bucketing as images.
- The browser worker wire carries the fixed-layout viewports, spine
  linearity, and spine idrefs of EPUB books.
- Progressive `BookSession` reads for EPUB, CBZ, CBR, and PDF, with a
  structure-only book header, on-demand resources and document text, search,
  statistics, progression, CFI operations, cancellation, and disposal.
  Sessions run in a resident VM isolate or browser worker, with per-session
  isolation and a byte-budgeted cache. File sessions read the source in the
  isolate; PDF sessions also expose original byte ranges and page text geometry.
- EPUB 3 rendition settings, page-list and landmarks navigation, and
  accessibility metadata in the package model.
- Typed book-opening results and typed failures for EPUB metadata updates.
- PDF page extraction diagnostics and comic page semantics for reader clients.
- Standalone Markdown, RTF, PalmDOC PDB, unencrypted eReader PDB, and Plucker
  PDB text parsing, each with format-specific public entry points.
- CHM reading with bounded LZX decompression, HTML topics, resources,
  hierarchical contents, Intel E8 restoration, and Windows-1251/1252/1256
  decoding selected by locale; Sony LRF reading with reflowed text, metadata,
  navigation, embedded images, and legacy headers through version 800.
- LRX2 plaintext metadata inspection, with protected book content rejected.
- DjVu visual pages with direct JPEG, JB2 masks, shared `Djbz` dictionaries
  referenced by `INCL`, progressive IW44 color and grayscale layers, and
  BG/FG/mask composition. Compressed `TXTz` hidden text becomes searchable
  content; `NAVM` bookmarks become navigation. File-based opens also resolve
  indirect documents from validated sibling components.
- TIFF and BigTIFF multi-page parsing with page dimensions, DPI, metadata,
  BMP output and self-contained JPEG-strip passthrough. Supported raster
  codecs include uncompressed, PackBits, LZW, Deflate/AdobeDeflate, and
  CCITT Group 3/4. Unsupported layouts and codecs fail with typed exceptions.
- KEPUB fixture validation through the existing EPUB parser, including an
  independently produced Standard Ebooks Kobo edition.
- eReader PML emphasis, headings, local links, PNG images, footnotes, and
  sidebars; Plucker inline formatting, links, headings, and 1/2/4-bit grayscale,
  8-bit system-palette, 4/8-bit custom-palette, and 16-bit RGB565 bitmaps.

### Behavior and limits

- `Unseal.read` and the existing eager APIs retain their full-book behavior.
  `BookSession` supports EPUB, CBZ, CBR, and PDF only; other formats throw
  `SessionUnsupportedFormatException`. Compressed CBR entries inflate during
  session opening; CBZ/CBR search returns no matches because pages contain no
  searchable text. Sessions do not perform OCR.
- Byte-based DjVu opens reject indirect documents. Use `Unseal.readFile`
  to resolve their sibling files on filesystem platforms. Shared dictionaries
  that inherit another dictionary and replacement visual codecs remain
  unsupported; `FGbz` palette recoloring is ignored.
- DjVu visual decoding is bounded at 2048 million cumulative pixels and
  1 GiB of raster bytes per book, with separate page and codec limits.
  TIFF/BigTIFF keeps a 128 MiB input limit, 1,024 pages, 256 million decoded
  pixels per book, and 128 MiB of decoded raster.

### Reliability and scope

- Added licensed or original fixtures, provenance, malformed-input tests,
  browser coverage, and format-specific size and decompression limits.
- The supported subset and remaining gaps for every new format are documented
  in the README. Pending extensions and validation gaps are collected in
  `doc/roadmap.md`.
- Added session parity, concurrency and cancellation tests, worker coverage,
  and deterministic fuzz cases for progressive PDF/comic sessions and scanned
  archives. DjVu text and selected raster pages are pinned against DjVuLibre;
  TIFF pixels are pinned against libtiff. Composed DjVu pages retain the
  documented hard-mask rendering differences.
- Corrected DjVu budget failure messages to report the current limits.
- Included maintained guides in the published package, removed completed
  campaign documents, and consolidated pending work in `doc/roadmap.md`.

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
