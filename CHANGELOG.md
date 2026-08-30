## Unreleased

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
- `Files`, `BinaryFile`, `TextFile`, `NavPoint` moved to
  `features/core`; the EPUB barrels re-export them for compatibility.
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
