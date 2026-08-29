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
