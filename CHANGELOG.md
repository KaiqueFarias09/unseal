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
- Optional per-publication inverted index (`BookSearchIndex`): ranked search
  over a book's canonical document text with BM25+ scoring (MiniSearch port),
  prefix and bounded fuzzy query modes, and hits that cut the original UTF-16
  text — the same offset space `Book.search` and CFI address. The tokenizer
  profile is self-contained (no ICU), identical on VM and browser, joins
  soft-hyphen and zero-width splits inside word runs, and folds Latin
  diacritics plus Greek and Cyrillic case; exotic scripts index verbatim.
- Incremental, cancellable construction: sections enter in finite batches
  (`BookSearchIndex.build` yields between batches; the coverage counters keep
  eligible, indexed, pending and failed sections apart), queries answer at any
  construction stage and carry the coverage that produced them — an empty
  result over a partial index never proves absence in the book.
- Versioned serialization: `serialize`/`deserialize` payloads record schema,
  tokenizer and normalization profile, identity and reading-order revision;
  import validates size, schema, profile, identity and structural bounds
  before trusting postings and can re-verify every section's text digest
  against a book or a text resolver. Changing text, order, tokenizer or
  profile refuses the index typed.
- Session integration: `BookSession.buildSearchIndex` drives bounded batches
  through the session's isolate or Web Worker (`searchIndex.*` ops) and
  `searchIndexed` answers ranked queries; `exportSearchIndex` /
  `importSearchIndex` move validated indexes between sessions over the same
  book; `dropSearchIndex` and `dispose` release the index. Persisting an index
  over PDF text is withheld until the P1 position-mapping acceptance
  (`SearchIndexUnsupportedException`); in-memory indexing over PDF works.
- Typed failures distinguish invalid argument, incompatible revision/profile,
  exceeded limit, cancelled build, disposed index and withheld persistence
  (`SearchIndex*Exception` hierarchy), across inline, isolate and worker
  paths.
- Indexed hits convert to locators (`IndexedSearchHit.toTextLocator`), keep
  the deterministic C05 tiebreak (score desc, occurrence asc, start asc, end
  asc), and preserve scores bit-identically through serialization round
  trips. `Book.search` and its suite are unchanged.
- Durable annotations with W3C exchange (`DurableAnnotations`,
  `AnnotationAnchor`): an additive envelope storing publication identity,
  source revision, section occurrence, extraction profile, text revision,
  UTF-16 bounds and bounded quote/context evidence for a selection — never
  the section text. Capture, a versioned structured-clone-safe codec
  (`encodeAnchor`/`decodeAnchor` with typed hostile-input failures and
  explicit refusal to export in-memory-only identities), and resolution
  answering exactly one of `resolved`/`ambiguous`/`missing`/
  `incompatibleRevision`/`unsupported`: the full identity tuple decides
  verified reuse; `AnchorPolicy.explicitMigration` re-finds the selection
  through exact, whitespace-normalized and bounded fuzzy passes (corrected
  editions carry their measured edit distance); indistinguishable ties stay
  ambiguous with capped candidates; another publication never migrates;
  `contextRecovery` re-finds unverified positions and says so. The W3C
  adapter (`W3cAnnotationAdapter`) implements the declared
  TextQuoteSelector/TextPositionSelector subset with code point ↔ UTF-16
  conversions (astral once, combining marks individually, mid-surrogate
  bounds refused as unrepresentable), loss-reported context truncation and
  explicit unknown-selector reporting. PDF pages join through their reading
  mode's canonical snapshots: an anchor captured over an indexed hit
  survives reopenings and full ↔ session mode switches on the long-document
  corpus. Ported from Hypothesis `a7b7400d` (BSD-2-Clause) with stricter
  ambiguity, Readium Kotlin `89b96c20` (BSD-3-Clause) as identity-layering
  reference, and the W3C Web Annotation Data Model as the selector contract.
  The v1 annotation/locator codecs and `relocateTextLocator` are unchanged.

### Fixed

- PDF text extraction composed the text matrix and CTM in the inverted
  order (`Tm ∘ CTM` instead of the PDF-specified `CTM ∘ Tm`), inflating
  x positions and advance widths by the Tm scale on every document that
  translates with `cm` before `BT` (cupsfilter does on every page, so
  the whole real-book corpus was affected). Coordinates now match
  PdfPig exactly on those books; the `Ts` rise composes in text space
  as the specification orders it. Canonical text is untouched — only
  geometry moves, and only where it was wrong.
- The whitespace-aligned table fallback no longer reports dozens of
  columns on dense prose: candidate column edges beyond the cap reject
  the page instead of fabricating a grid.

- CBR reads compressed RAR 5 entries: algorithm version 0, compression
  methods 1-5, the delta / E8 / E8-E9 / ARM filters, UTF-8 entry names,
  and declared dictionaries from 128 KiB through 64 MiB, in both the
  eager parse and progressive sessions. Output is byte-identical to two
  independent reference decoders (rardecode at `ad22ba91a2ab` and
  libarchive at `87dec938`, verified through `tool/rar5_compare.dart`).

### Changed

- RAR 5 container parsing is now strict and shared by both readers:
  every header's CRC-32 verifies, names decode as UTF-8, vints and
  header sizes are bounded, and structural corruption fails typed
  instead of silently truncating the entry list. A declared data
  CRC-32 verifies after decoding — a declared zero is a real checksum;
  the absent flag never rejects. RAR 4 behavior is unchanged.
- Out-of-subset RAR 5 records fail typed naming the reason: split
  (multi-volume) archives and entries, solid streams, encrypted
  entries and archives, links/redirects, compression algorithm versions
  above 0, reserved methods 6-7, dictionaries above 64 MiB, and entries
  with unknown unpacked size. RAR 5 decoding allocates exactly the
  declared output before decompressing.

- JPEG 2000 (ISO/IEC 15444-1) image decoding behind the PDF `JPXDecode`
  filter: a pure-Dart port of a pinned OpenJPEG revision covering J2K
  codestreams and JP2 wrappers, unsigned 8-bit grayscale and RGB, the
  reversible 5/3 and irreversible 9/7 wavelets, LRCP and RLCP progression,
  single and multiple tiles, RCT/ICT component transforms, SOP/EPH markers,
  segmentation symbols, custom precincts, and multiple quality layers.
  Direct `JPXDecode` streams and `/ASCII85Decode /JPXDecode` chains
  extract as images; every allocation is budgeted before it happens and
  every unsupported feature (arithmetic coding bypass, CMYK/palettes,
  `SMaskInData`, geometry conflicts) fails typed. Lossless decodes are
  byte-exact against the OpenJPEG oracle corpus; lossy decodes stay inside
  tolerances fixed before the first Dart comparison. VM and compiled
  browser decodes are byte-identical.

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
