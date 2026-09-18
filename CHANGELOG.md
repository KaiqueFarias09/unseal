## 3.3.0 - September 7, 2026

### Added

- **Calibre format expansion**: TXT/TXZ, HTML/HTMLZ, DOCX, ODT, AZW4,
  CB7 and CBC are now detected and parsed into the common book model.
  Document formats preserve metadata, navigation and reflowable HTML;
  archive formats preserve styles, images and fonts where present, while
  AZW4 retains its embedded PDF for downstream facsimile rendering.
- **PDF encryption (standard security handler)**: revisions 2-6 of
  the ISO 32000-1 algorithm — RC4 40/128-bit, AES-128 and AES-256
  (revision 5/6 with the algorithm 2.A key derivation and 2.B hash,
  including `/Perms` validation) — over a pure-Dart port of the
  primitives on `pointycastle` (the package's first crypto
  dependency). `PdfDocument.parse` gained an optional `password`;
  empty-user-password documents (owner-restricted) open
  transparently, and every string and stream decrypts before the
  existing extraction pipeline runs, so encrypted books carry the
  same text/reflow invariants as plain ones.
- **CCITTFaxDecode and JBIG2Decode image filters**: pure-Dart ports
  of pdf.js v3.11.174's `ccitt.js` and `jbig2.js` (G3 1D/2D, G4/MMR
  with full `/DecodeParms` support; arithmetic (MQ) integer and
  bitmap decoding, Huffman tables, refinement, pattern dictionaries
  and halftone regions; `/JBIG2Globals` shared dictionaries). Page
  images drawn from these XObjects render as grayscale PNGs through
  `parsePdfBook`'s image callback. Robustness: allocation budgets,
  decode-decision budgets and bounded symbol loops turn corrupt or
  hostile streams into clean `PdfException`s (verified by byte-level
  mutation tests).
- **Image parity harness**: `tool/pdf_parity.dart --image` measures
  every CCITT/JBIG2 image XObject's raster against pdf.js
  v3.11.174 (a Node oracle in `tool/reference/`, or committed PGM
  goldens). First runs: CCITT corpus **10 images / 1.31M pixels at
  100.0000%**; JBIG2 arithmetic paths **100.0000%** on
  `jbig2_symbol_offset` and all 8 `issue12963` page scans (69.5M
  pixels). The real scanned-book Huffman corpus now reaches
  **199 images / 904,063,634 pixels at 100.0000%**, including
  Flate-compressed globals, OOB-terminated text regions and signed
  custom-table bounds.
- **PDF validation corpus and parity harness**: a Project Gutenberg
  corpus (8 public-domain books, ~3.8 MB, fetched reproducibly by
  `tool/fetch_pdf_corpus.dart`; Gutenberg no longer publishes its own
  PDFs, so the fixtures are generated from the official text files
  via the macOS print pipeline) locks the canonical-text invariant
  per book. `tool/pdf_parity.dart` measures extraction against
  Poppler (`pdftotext` per page), reflow against Calibre's own
  `ebook-convert`, and metadata against `pdfinfo` — all against the
  binaries bundled with the installed Calibre app. First corpus run:
  **1,388 pages at 1.0000 mean similarity, 100% of pages above 0.9,
  reflow 1.0000 on all 8 books, metadata 24/24 fields matching**.
- **Font fidelity**: real standard-14 width tables (Adobe core14
  AFMs as distributed by Apache PDFBox; provenance header included)
  replace the per-family averages when a font carries no `/Widths`,
  and Type0 fonts with an embedded `/Encoding` CMap now decode
  one-byte codes and measure `/W` widths by CID through the
  `cidrange` mapping (plus the previously unparsed range-array form
  of `/W`).
- **Robustness**: the LZWDecode stream filter (with `/EarlyChange`),
  exact rotated-text bounding boxes from the text matrix, and a
  deterministic byte-level fuzz suite (1,500 mutations over real and
  synthetic fixtures) that surfaced and fixed a latent crash — a
  zero font size now degrades instead of poisoning the reflow
  statistics with NaN.
- **PDF support**: a pure-Dart PDF pipeline with zero new
  dependencies. `parsePdfBook` reads the document structure (classic
  cross-reference tables, PDF 1.5 cross-reference streams, object
  streams and a scan-based recovery for broken files), extracts
  per-page text (content-stream interpreter, simple fonts through the
  Adobe encodings plus `/Differences` glyph names, Type0/CID fonts
  through ToUnicode CMaps, per-code widths) and reflows it into one
  HTML section per page — a behavioral port of Calibre's
  `reflow.py` heuristics (paragraph coalescing with the unwrap rule,
  automatic header/footer removal, indent and alignment statistics,
  heading detection) adapted to per-page sections. The reflowed pages
  carry the canonical-text invariant: `documentText` of a page's HTML
  is exactly that page's extracted text stream (`PdfPageText.text`),
  so search, `TextLocator` offsets, progression and the viewer's two
  reading modes all address one character space; section `i` is page
  `i`, so `PageLocator` falls out free. Bookmarks become `Navigation`
  (`page_N.html#page_N` anchors), metadata follows Calibre's
  `pdf.py` behavior (Info dictionary plus XMP consolidation, ISBN
  from keywords), and `PdfBook` keeps the original bytes for the
  viewer's facsimile mode. Encrypted documents throw
  `PdfEncryptedException`; `PdfException` covers unreadable
  structure. Benchmarks: `benchmark/pdf_benchmarks.dart` (in-repo
  real-writer fixture plus an optional `ELIVRE_BENCH_PDF_DIR`
  corpus).
- **Book locators**: a versioned, format-neutral `BookLocator` union
  (`TextLocator` in the `documentText` space with optional
  `TextQuote` relocation context, `CfiLocator` carrying an EPUB CFI,
  `PageLocator` for comics and future PDF), with a JSON codec
  (`locatorToJson`/`locatorFromJson`, envelope versioned via `v`),
  `SearchMatch.toTextLocator`, and pure fuzzy relocation
  (`relocateTextLocator`) that re-anchors a quote after edition
  drift, preferring the original section and scoring context
  agreement.
- **EPUB CFI ranges**: `buildEpubCfiRange(contentIndex, startOffset,
  endOffset)` emits the spec's three-path range form (boundary
  subpaths relative to the leading path, round-tripping through
  `EpubCfi.tryParse`), and `resolveCfi` accepts ranges — the new
  `EpubCfiLocation.endCharOffset` carries the exclusive range end
  (null for points; cross-section ranges resolve to null).
- **TOC target resolution**: `NavResolution.navTargetOf` parses raw
  `NavPoint.content` strings (EPUB href/fragment, MOBI `filepos`,
  bare fragments), and `resolveNavigation` resolves them to
  `NavTarget` positions
  (section index plus, for EPUB anchors, a `documentText` offset).
- **Book progression**: `BookProgression.of(book)` measures
  per-section character totals and exposes `fractionOf` /
  `sectionFraction` (0..1, clamped) for reading progress and
  cross-device position sync; non-text books fall back to section
  indexing.
- **Portable annotations**: `HighlightRecord`/`BookmarkRecord` value
  types (Calibre palette or custom colors, decorations, notes,
  dual CFI), a versioned tolerant JSON codec
  (`encodeAnnotations`/`decodeAnnotations`, `formatVersion: 1`) and
  Calibre-parity merges
  (`mergeHighlights`/`mergeBookmarks` — newest timestamp wins per
  identity, ties keep local, survivors re-sorted by position;
  behavioral re-expression of `annotations.pyj`).
- **Worker search and CFI ops**: the web worker keeps the resident
  parsed book and answers `search`/`cfiResolve`/`cfiBuild`
  (`WorkerBookReader.searchInWorker` and friends), with the op
  handling factored into the pure `runWorkerOp`; the main-thread
  client tracks residency and returns null for inline fallback,
  `FormatException` crosses the wire typed, and native runtimes keep
  these ops on the calling thread.
- **Search modes**: `BookSearch.search` gains `mode`
  (`SearchMode.contains` default, `wholeWords`, `regex`,
  `proximity`) and `nearChars`, porting Calibre's query handling.
  Whole-word wraps every token in word boundaries under the same
  tolerant leniency; regex compiles the query verbatim (multiline,
  throwing `FormatException` when invalid); proximity (Calibre's
  "near") requires every word inside a window of `nearChars`
  characters (default 60), with a trailing all-digits query token
  overriding the interval. Soft-hyphen tolerance now also folds
  straight quotes onto curly ones and collapses whitespace runs
  like `text_to_regex`.
- **RTL metadata**: the EPUB spine's `page-progression-direction`
  attribute is parsed onto `Spine.pageProgressionDirection`
  (`'rtl'`/`'ltr'`, null when undeclared), so readers can mirror
  page flow for RTL books.

### Performance

- Search no longer rescans `files.html` linearly for every section
  (O(n²) → map lookup).

### Fixed

- **KF8 books with image containers no longer crash**: `MobiContainer`
  assigned its `late final isImageContainer` twice whenever the `CONT`
  record carried an EXTH 539 `application/image` entry — every AZW3
  using CONT/CRES-wrapped images threw `LateInitializationError`.
  Found by the new synthetic CONT/CRES tests.
- **KF8 headers with a single FDST section no longer crash**:
  `MobiHeader` assigned `fdstIndex` twice when `fdstCount <= 1`,
  throwing `LateInitializationError` during the parse.
- **RAR 5 reading matches the format spec**: the reader treated the
  main archive header (type 1) as the end of the archive — real RAR 5
  files yielded zero entries — and computed header ends without the
  header-size vint length, misaligning every block. End of archive is
  type 5; the main header is now skipped like any other non-file
  block.

### Performance

- **FB2 metadata reads parse only the metadata**: `readMetadataSync`
  for FB2 slices the leading `<description>` element (plus the single
  cover `<binary>`) out of the raw bytes instead of building the DOM
  for the whole document and base64-decoding every image — ~15×
  faster (23 ms → 1.6 ms on the 3.4 MB fixture). Malformed slices
  fall back to the full parse, so results are unchanged.
- **KF8 markup expansion is ~2× faster**: kindlegen `aid`/`cid`
  attributes are stripped by a single-pass scanner instead of a
  backtracking regex over every tag, and the flow/image reference
  passes are skipped entirely for parts that carry no
  `kindle:flow`/`kindle:embed` reference (parsing output is
  byte-identical, verified by differential snapshots).
- **`extractPlainText` is a single pass** (58 MB/s from 15 MB/s on
  the benchmark chapter): markup removal, entity decoding and
  whitespace collapsing share one left-to-right scan that bulk-copies
  plain text spans. `book.statistics` first access drops ~3× (it maps
  `plainText` over every content file). A differential check against
  the previous implementation over every fixture file found no output
  changes on real book content.
- **Double escaped entities now decode once** (`&amp;lt;` yields
  `&lt;`, browser behaviour, instead of `<`); entities expanding to
  `<`/`>` remain text, as before. Documented in the new dedicated
  `extractPlainText` test suite.
- **PalmDoc decompression is now linear**: `decompressPalmdoc` used to
  snapshot the whole output buffer on every back reference (quadratic
  overall). Full parses drop from ~118 ms to ~7 ms (MOBI 6), ~133 ms
  to ~16 ms (KF8) and ~142 ms to ~16 ms (joint files) on the benchmark
  fixtures.
- **EPUB manifest resolution is O(n)**: `extractFiles` resolves items
  through a prebuilt path map instead of scanning every archive entry
  per manifest item.
- **Shared compiled patterns**: the KF8 markup pipeline, MOBI 6 markup
  conversions, chapter splitting and `extractPlainText` reuse
  top-level `RegExp`s instead of recompiling them per tag, per
  chapter or per call.
- MOBI text records strip control bytes in bulk spans instead of byte
  by byte, and cp1252 decoding goes through a 256-entry code unit
  table.
- `EpubBook.fromBytes` no longer copies the input when it already is
  a `Uint8List`.

## 3.2.0 - August 29, 2026

### Added

- `Book.readingOrder`: the content files in reading order. EPUB
  resolves the OPF spine (exposed on `EpubBook.spinePaths` too);
  other formats fall back to the extraction order; comics list their
  pages with `isHtml: false`.

## 3.1.0 - August 29, 2026

### Added

- **Series support**: `BookMetadata.series` / `seriesIndex` from EPUB
  `calibre:series` metas, EPUB 3 `belongs-to-collection` +
  `group-position` and FB2 `<sequence name number>`.
- **Calibre sidecar OPF**: `EBook.readMetadataFromPath/File` merge a
  sibling `<basename>.opf` / `metadata.opf` over the book's own
  metadata (`mergeBookMetadata` is public for custom merges).
- **Filename fallback**: books without internal metadata get
  title/authors from the Calibre `Title - Author.ext` pattern.
- **`BookStatistics`**: `book.statistics` exposes `wordCount`,
  `characterCount` and `estimatedReadingTime(wordsPerMinute: 200)`.
- **Plain text**: `TextFile.plainText` (and `extractPlainText` /
  `countWords` utils) strip markup and decode entities.
- **Cover dimensions**: `BookCover.width`/`height` parsed from
  JPEG/PNG/GIF/BMP/WebP headers without decoding (`imageSize`).
- **MOBI 6 chapters**: `MobiBook.chapters` splits the single HTML
  stream at the TOC anchors, including the front-matter part.
- **Comic books**: CBZ (zip + `ComicInfo.xml`) and CBR (RAR 4/5 with
  stored entries) with natural page ordering, page count and
  first-page cover.

### Fixed

- MOBI 6 internal links now normalize `filepos` numbers so padded
  hrefs (`#filepos0000198965`) match their anchor ids.
- EPUB binary extraction no longer copies every archive entry a
  second time (views over the decoded buffers), halving peak memory
  of full parses.

## 3.0.0 - August 29, 2026

Multi-format release: eLivre now parses EPUB, MOBI, AZW3 (KF8) and FB2
with full feature parity — metadata, cover, content files, stylesheets,
fonts and navigation — from a single format-agnostic API.

### Added

- `EBook` entry point: `openFromBytes`/`openFromFile`/`openFromPath`
  detect the format by magic bytes and return the fully parsed book in
  a background isolate; `readMetadataFrom*` performs a fast
  metadata-only read without extracting content.
- `Book` / `BookMetadata` / `BookCover` / `BookFormat`: the common,
  format-agnostic result types every module maps into.
- MOBI support: PDB/MOBI/EXTH headers, PalmDoc and HUFF/CDIC
  decompression, MOBI 6 content extraction (filepos anchors, recindex
  image mapping, fonts), KF8 (AZW3) skeleton/div reassembly, FDST
  flows (CSS/SVG), CONT/CRES wrapped resources, NCX-based navigation
  and joint MOBI 6 + KF8 files. DRM-protected files raise
  `DrmProtectedException`.
- FB2 (and zipped FB2) support: title-info/publish-info metadata,
  coverpage covers, body-to-XHTML conversion with notes bodies,
  internal link rewriting and section-based navigation.
- Format detection helpers (`detectFormat`, `refineMobiFormat`) and an
  image magic-byte sniffer (`sniffImageType`).
- `readEpubMetadata` fast path and a metadata-only EPUB read in
  `EBook.readMetadataFrom*`.

### Changed

- `Navigation` is now a concrete, format-agnostic structure
  (`title` + `navPoints`); EPUB 3 `nav.xhtml` documents are supported
  in addition to NCX.
- `Files`, `BinaryFile`, `TextFile`, and `NavPoint` moved to the
  shared foundation layer and are exported from the main library.
- Archive entries are matched by exact normalized path instead of
  substring matching.

### Fixed

- EPUB cover resolution now follows the spec precedence (EPUB 3
  `cover-image` property, EPUB 2 `<meta name="cover">`, guide
  references, then heuristics) instead of an id-substring match.
- `EpubBook.fromFile` no longer reads the file before checking that
  it exists.
- Incomplete OPF packages no longer crash with `StateError` on
  optional EPUB 3 metadata fields.

## 2.0.0 - February 6, 2024

-  Move readBook functionality to EpubBook class
-  Now is possible to create a EpubBook from bytes, file or path
-  Add getters for title, creator, publisher, language, uid, version, content and images

## 1.0.4 - February 5, 2024

-   Pin archive dependency to `^3.1.6` for better support
-   Pin xml dependency to `^6.0.1` for better support
-   Pin path dependency to `^1.8.1` for better support

## 1.0.3 - February 5, 2024

-   Pin collection dependency to `^1.15.0` for better support

## 1.0.2 - February 5, 2024

-   Pin path dependency to `^1.8.0` for better support

## 1.0.1 - January 15, 2024

-   Add new properties to EPUB 3.0 package

## 1.0.0 - January 12, 2024

-   Initial release of the project
