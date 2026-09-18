## 3.0.0 - September 18, 2026

This is the consolidated eLivre v3 release. Intermediate development
labels were never published; their changes are included here as one major
release with breaking changes after 2.0.0.

### Added

- **Format-neutral reader**: `BookReader.openFromBytes`/
  `openFromPath`/`parseBook` detect the supported format and return the
  common `Book` model; `readMetadataFromBytes`/
  `readMetadataFromPath` provide fast metadata-only reads, including
  filename and OPF sidecar fallbacks.
- **Common models and format detection**: `Book`, `BookMetadata`,
  `BookCover`, `BookFormat`, `Files`, `TextFile`, `BinaryFile`,
  `Navigation`, `NavPoint`, `detectFormat`, `refineMobiFormat` and
  `sniffImageType` are shared across every parser.
- **MOBI and AZW3/KF8**: PDB/MOBI/EXTH headers, PalmDoc and HUFF/CDIC
  decompression, MOBI 6 chapters and anchors, KF8 skeleton/div
  reassembly, FDST flows, CSS/SVG, CONT/CRES resources, NCX navigation,
  joint MOBI 6 + KF8 files, fonts and image mappings. DRM-protected
  files raise `DrmProtectedException`.
- **FB2/FBZ**: metadata, coverpage covers, declared encodings, notes,
  links, styles, body-to-XHTML conversion and section navigation.
- **Metadata and reading data**: series and series indexes, Calibre
  sidecar OPF merging, filename metadata fallback, `BookStatistics`,
  `TextFile.plainText`, `extractPlainText`, `countWords`, cover
  dimensions, Calibre-compatible title/author sort keys, `bookProducer`
  metadata and physical `archiveEntries` inventories.
- **Search and reading operations**: full-text search, versioned
  `BookLocator`/`TextLocator`/`CfiLocator`/`PageLocator` values, fuzzy
  text relocation, EPUB CFI ranges, TOC target resolution, reading
  progression, portable annotations, OPDS feeds and public search
  result types.
- **EPUB reading features**: EPUB 3 media overlays/SMIL parsing,
  `readEpubMetadata`, EPUB metadata writing, `Book.readingOrder`,
  reading-order resolution, RTL page flow and EPUB 2/3 navigation and
  CFI support.
- **Additional formats**: TXT/TXZ, HTML/HTMLZ, DOCX, ODT, AZW4, CBZ,
  CBR, CB7 and CBC, with shared metadata, navigation, resource and
  cover behavior where the format supports it.
- **Reading heuristics**: punctuation normalization, scene-break
  detection, chapter guessing and line unwrapping for reflowable text.
- **Deterministic robustness infrastructure**: tracked fuzz seeds and
  generated cases carry a reproducible manifest (hashes, sizes, format
  families and structural landmarks). The normal suite keeps a quick release
  gate, while opt-in tagged campaigns run deterministic byte/structure
  mutations in killable isolates with deadlines.
- **Bounded input handling**: empty or malformed books fail through typed
  eLivre exceptions. ZIP-backed formats reject encrypted entries, symbolic
  links, unsupported compression, forged sizes, entries over 512 MiB,
  aggregate expansion over 1 GiB, and excessive expansion ratios before or
  during inflation.
- **PDF and FB2 parser safety**: PDF marked-content dictionaries are consumed
  with guaranteed lexer progress, and explicit nesting limits protect PDF
  object graphs and FB2 XML trees. Focused adversarial tests cover these
  boundaries and their typed failure contracts.
- **Structured performance tooling**: one benchmark matrix covers all 16
  supported formats and can emit versioned JSON, compare same-machine
  baselines, or alternate A/B commands. A separate, strictly opt-in Calibre
  library sweep is read-only, resumable, timeout-bounded and anonymizes files
  with persisted random IDs whose private map stays outside the repository.

- **Calibre format expansion**: TXT/TXZ, HTML/HTMLZ, DOCX, ODT, AZW4,
  CB7 and CBC are detected and parsed into the common book model.
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
  pixels). The real scanned-book Huffman corpus covers
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
  and Type0 fonts with an embedded `/Encoding` CMap support
  one-byte codes and measure `/W` widths by CID through the
  `cidrange` mapping (plus the previously unparsed range-array form
  of `/W`).
- **Robustness**: the LZWDecode stream filter (with `/EarlyChange`),
  exact rotated-text bounding boxes from the text matrix, and a
  deterministic byte-level fuzz suite (1,500 mutations over real and
  synthetic fixtures). Zero-sized fonts degrade safely without introducing
  NaN into reflow statistics.
- **PDF support**: a pure-Dart PDF pipeline, with `pointycastle` used by
  the standard security handler for encrypted documents. `parsePdfBook`
  reads the document structure (classic
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
  overriding the interval. Soft-hyphen tolerance also folds
  straight quotes onto curly ones and collapses whitespace runs
  like `text_to_regex`.
- **RTL metadata**: the EPUB spine's `page-progression-direction`
  attribute is parsed onto `Spine.pageProgressionDirection`
  (`'rtl'`/`'ltr'`, null when undeclared), so readers can mirror
  page flow for RTL books.

### Changed

- **Breaking public API**: the former `EBook` entry point is replaced by
  `BookReader`, whose final contracts are `openFromBytes`/
  `openFromPath`/`parseBook` and `readMetadataFromBytes`/
  `readMetadataFromPath`/`readMetadataSync`.
- **Format entry points**: standalone format barrels expose explicit
  parser and metadata functions, while the shared foundation owns the
  common file and navigation entities.
- **Search contracts**: search argument names use `isCaseSensitive` and
  `isTolerant`; result fields use `isTruncated`; the complete
  `SearchResults`, `SearchMatch` and `SearchMode` contract is public.
- **Execution model**: native parsing remains on the calling runtime,
  while browser parsing can use a resident web worker behind platform
  adapters; typed failures cross the worker boundary.
- **Navigation and archive resolution**: `Navigation` is a concrete,
  format-agnostic structure; EPUB 3 `nav.xhtml` is supported alongside
  NCX, and archive entries use exact normalized paths instead of
  substring matching.
- **Dependencies and platform baseline**: the package now requires Dart
  3.8 or newer and uses `web`, `pointycastle` and `koni_archive` for
  browser, PDF-security and archive capabilities.
- **Release validation**: CI has independent Dart VM and browser lanes so
  conditional implementations are compiled and tested on both runtimes. The
  publication archive is explicitly filtered by `.pubignore`, and PDF
  fixtures are marked binary for stable Git handling.
- Search resolves sections through a prebuilt map instead of an O(n²)
  repeated scan.

### Fixed

- EPUB cover resolution now follows spec precedence: EPUB 3
  `cover-image`, EPUB 2 `<meta name="cover">`, guide references, then
  heuristics, instead of an id-substring match.
- Incomplete OPF packages no longer crash with `StateError` on optional
  EPUB 3 metadata fields.

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

### Removed

- A machine-specific experimental outlier profiler was removed from the
  release. Its private-path assumptions and non-portable state made it unsafe
  to ship; the reproducible benchmark matrix, baseline comparator, and
  privacy-preserving library sweep cover the supported workflows instead.
- The legacy `EBook` entry point and its `openFromFile`/
  `readMetadataFromFile` contracts were replaced by `BookReader`.
- The public `EpubCfi.serialize()` alias was removed in favor of the
  current CFI codec.
- EPUB deep-import compatibility shims and obsolete internal file and
  navigation aliases were removed; consumers should use the public
  barrels and foundation entities.
- Legacy annotation paths and the `eLv1` compatibility/fallback wire
  paths were removed from the final v3 contracts.
- The obsolete `parser` pubspec topic was removed.

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
