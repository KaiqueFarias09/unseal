# Understand the unseal codebase

This guide explains how unseal turns book files into one model that reading applications can use. It is for developers who know Dart but do not yet know the details of EPUB, MOBI, PDF, office documents, or comic archives.

The guide follows the code in this repository. It explains each feature, the reason behind its internal layers, and the job of every Dart file under `lib/`.

Use it in two ways:

1. Read "The whole library in one picture" before reviewing any feature.
2. Open a feature section and read its files in table order. The first files show the public result and orchestration. The later files contain format details.

This document describes Unseal itself. Consumer applications own interactive rendering, speech, and audio playback. Those concerns do not belong in a format parser here.

Paths that start with `features/`, `foundation/`, or `platform/` are relative to `lib/src/`. Paths that start with `lib/` or `web/` are relative to the repository root.

## Find the part you need

| If you want to understand... | Read... |
| --- | --- |
| The common book model and shared policies | Foundation, then Detection and Reading |
| Reflowable text and document formats | TXT, HTML, DOCX, ODT, FB2, then EPUB |
| Image-first or binary formats | CBZ/CBR, CB7/CBC, MOBI/AZW3, AZW4, PDF, then DjVu |
| Positions and reader-facing capabilities | Search, Locators, Annotations, CFI, and Reading progression |
| Catalogs that point to books | OPDS and Calibre |
| Native isolates, browser workers, and serialization | Platform |

## The whole library in one picture

Most calls follow this path:

```mermaid
flowchart LR
    A["File path or bytes"] --> B["Unseal"]
    B --> C["Format detection"]
    C --> D["Format parser"]
    D --> E["Book model"]
    E --> F["Viewer, search, annotations, or narration"]

    D --> G["Metadata"]
    D --> H["Reading order"]
    D --> I["Navigation"]
    D --> J["HTML, images, fonts, and other resources"]
```

The input is a sequence of bytes. Detection identifies the family of the file. Dispatch chooses one parser. The parser translates its format into `Book`, `BookMetadata`, `Files`, `Navigation`, and `ReadingOrderItem`.

That translation is the central job of unseal. Consumers do not need one reading interface for EPUB and another for DOCX. They receive the same concepts even though the source formats store them in very different ways.

### The common result

Every parsed publication is a `Book`:

- `format` says which source format produced the book.
- `metadata` contains the title, authors, language, series, cover, and other catalog information.
- `files` groups extracted HTML, CSS, images, fonts, and other resources.
- `navigation` is the table of contents in a common tree structure.
- `readingOrder` lists the content in the order in which a reader opens it.
- `archiveEntries` records the physical files inside formats that preserve an archive inventory. TXTZ, HTMLZ, DOCX, ODT, and EPUB populate it; not every format backed by an archive does.
- `statistics` derives word count and reading-time estimates from the extracted text.

`DocumentBook` is the common concrete result for formats that unseal converts into HTML: TXT/TXTZ, HTML/HTMLZ, DOCX, and ODT. FB2, EPUB, MOBI, comics, and PDF retain specialized book types because consumers need additional information from those formats.

## Vocabulary used throughout the code

You only need a small set of format terms to understand most of the repository.

| Term | Meaning in this project |
| --- | --- |
| Bytes | The raw numbers read from a file before unseal knows what they represent. |
| Format detection | Inspection of signatures and bounded content to identify a file family. A file extension alone is not trusted. |
| Container | A file that stores other files or records. ZIP, RAR, 7-Zip, and Palm Database are containers. PDF instead stores a connected graph of objects and streams. |
| Package | A container plus rules that say which internal files matter and how they relate. EPUB, DOCX, and ODT are ZIP packages. |
| Package part | One named file inside a package, such as `word/document.xml`. A part can describe content or relationships; a resource is content the finished publication exposes; a ZIP entry is merely the physical container member. |
| Parser | Code that reads source structures and turns them into Dart values. |
| Codec | Code that encodes, decodes, compresses, or decompresses bytes. A codec does not decide the reading order. |
| XML and namespace | XML is a tree-shaped text format. A namespace qualifies element names so vocabularies such as Dublin Core and OpenDocument can coexist without name collisions. |
| DOM | An in-memory tree of a parsed HTML or XML document. Parsers navigate elements, attributes, and text nodes through it. |
| BOM and text encoding | A byte-order mark can identify how bytes represent Unicode text. When no BOM exists, a format may provide an encoding declaration or require a defined fallback. |
| Base64 | A way to represent binary bytes as text. FB2 uses it to place images inside XML. |
| Metadata | Descriptive information such as title, author, language, publisher, and cover. |
| Resource | Content used by the publication, such as an image, font, stylesheet, or audio file. |
| Media type or MIME type | A standardized content label such as `image/jpeg` or `application/xhtml+xml`. It is more precise than a filename extension. `BookFile.type`, despite its name, normally stores the extension without the leading dot. |
| Manifest | A format-owned list of resources. EPUB uses an OPF manifest to give each resource an identifier and media type. |
| OPF | The EPUB package document. It holds metadata, the manifest, the spine, and related package declarations. TXTZ and HTMLZ may use an OPF file only as a metadata sidecar; that does not make them EPUBs. |
| Spine | EPUB's ordered list of manifest item identifiers that make up the main reading sequence. Manifest order, spine order, and table-of-contents order can differ. |
| NCX | The older XML table-of-contents format normally used by EPUB 2 and also represented in some Kindle data. |
| SMIL | An XML timing format. A `seq` groups items in sequence; a `par` synchronizes text and audio in parallel. unseal parses timing, while another package plays the audio. |
| Sidecar | A neighboring file that adds information to the main book without being stored inside it, such as `metadata.opf`. |
| WordprocessingML | The XML vocabulary used by DOCX for paragraphs, runs, styles, numbering, and document relationships. |
| DOCX relationship | A mapping in a `.rels` part from an identifier in document XML to another package part or an external URL. |
| ODF or OpenDocument | The package and XML standard used by ODT. It is separate from Microsoft's DOCX vocabulary. |
| Glyph and CID | A glyph is the shape a font draws. In a composite PDF font, a CID identifies a glyph, but a separate Unicode mapping is usually needed to recover the intended character. |
| PDF content stream | A small program of drawing operators that places text, images, and graphics on a page. It is not stored as paragraphs. |
| PDF XObject | A reusable image or form referenced by a content stream. The current extractor follows image XObjects but does not enter form XObjects. |
| Predictor | A reversible row transformation applied before compression. PDF decoding reverses it after Flate or LZW decompression. |
| Crypt filter | A PDF rule that selects the cipher used for a particular stream or string. |
| Huffman, arithmetic, and MMR coding | Three compact binary representations used by the supported compression formats. Their decoders turn code bits and probability states back into symbols, numbers, or black-and-white rows. |
| Reading order | The sequence of chapters or pages. In EPUB this comes from the spine. In comics it comes from sorted image names. |
| Navigation | A hierarchy of named destinations, usually shown as a table of contents. |
| Reflow | Conversion of fixed or loosely positioned content into text and blocks that adapt to the screen width. |
| Facsimile view | Display of the original PDF pages with their original geometry. The Viewer can use the bytes retained by `PdfBook` for this mode. |
| Fixed layout | Content whose original page geometry matters. PDF and most comics are fixed-layout formats. |
| OCR | Recognition of characters inside an image. unseal does not perform OCR, so an image-only scan has no searchable text unless the PDF already contains a text layer. |
| Locator | A portable description of a reading position. It is separate from the viewer's temporary scroll state. |
| CFI | EPUB Canonical Fragment Identifier, a standard path to a position inside an EPUB document. |
| DRM | Access control that requires authorization or a key the library does not own. unseal reports unsupported DRM instead of pretending that the file is corrupt. |

## Supported publication formats

| Format | What it contains | What unseal produces |
| --- | --- | --- |
| EPUB 2 and EPUB 3 | A ZIP package with metadata, HTML chapters, resources, and navigation. | `EpubBook` with its package model, reading spine, resources, and navigation. EPUB 3 also exposes page-list, landmarks, rendition, and accessibility metadata. Consumers parse optional SMIL files separately. |
| KEPUB | A Kobo-modified EPUB package. | `EpubBook` tagged as `BookFormat.epub`; Kobo spans in XHTML remain available. |
| MOBI 6 | A Palm Database container with compressed legacy Kindle markup. | `MobiBook` with reconstructed HTML, resources, metadata, and navigation. |
| PalmDOC PDB | A `TEXt/REAd` Palm Database with plain text in 4096-byte records. | `DocumentBook` tagged as `BookFormat.palmdoc`. |
| eReader PDB | A `PNRd/PPrs` Palm Database containing compressed PML text, image and note records, and optional metadata. | `DocumentBook` tagged as `BookFormat.ereader`, with reading-oriented HTML, basic styles, local links, PNG images, footnotes, sidebars, and title/author. Exact PML layout is not reconstructed. |
| Plucker PDB | A `Data/Plkr` Palm Database containing compressed HTML-like pages and Palm bitmap records. | `DocumentBook` tagged as `BookFormat.plucker`, with readable paragraphs, paragraph links, title, and supported 1/2/4-bit grayscale, 8-bit palette, and RGB565 direct-color images. Custom palettes and RGB565 are covered by generated fixtures only; no real book with those bitmap variants has been verified. |
| Sony LRF | A BBeB binary container with indexed objects, page streams, metadata XML, and image streams. | `DocumentBook` tagged as `BookFormat.lrf`, with ordered reflowed pages and extracted images for versions 1–800 and 801+. |
| Sony LRX | Calibre recognizes legacy `LRX` and `ftypLRX2` markers; Sony's public references describe OpenMG-protected BBeB and separately identify Marlin-protected Reader content, but do not specify the LRX wrapper. | `readLrxMetadata` reads a plaintext metadata stream from a nested LRX2 `bbeb` box; full book parsing throws `DrmProtectedException`. The box path is oracle-derived and tested with synthetic bytes. |
| AZW3 or KF8 | A newer Kindle representation, sometimes stored beside MOBI 6 in one file. | `MobiBook` tagged as `BookFormat.azw3`. |
| AZW4 | A Palm Database wrapper whose payload is a PDF. | `PdfBook` tagged as `BookFormat.azw4`. |
| PDF | A graph of numbered objects that describes pages, fonts, drawing commands, images, and metadata. | `PdfBook` with original bytes, page geometry, extracted text, images, outline, and reflowed HTML. |
| DjVu JPEG, JB2, and bounded IW44 subset | An IFF document with INFO, direct BGjp JPEG, local or shared Sjbz JB2 masks, progressive BG44/FG44 IW44 layers, TXTz/TXTa text, and NAVM bookmarks. | `DjvuBook` with JPEG/BMP page images, geometry, searchable text, navigation, and source bytes. File-based reads resolve indirect sibling components. Chained dictionaries and replacement visual codecs fail typed; FGbz palette recoloring is ignored. |
| TIFF and BigTIFF | A classic TIFF or BigTIFF header whose IFD chains describe pages of strip- or tile-organized raster. | `TiffBook` with BMP page images (or a passed-through self-contained JPEG strip), dimensions, resolution, and original bytes. Tiled raster, planar=2, palette, LogLuv, JPEGTables-abbreviated strips, old-style JPEG, and reversed FillOrder fail typed. |
| CHM | An ITSF compiled HTML Help archive with compressed topic streams. | `DocumentBook` with ordered HTML topics, resources, title, and hierarchical contents. |
| TXT | Plain text with no formal book structure. | One HTML document, filename or header metadata, and a single navigation point. Markdown and Textile headings are recognized only when that input mode is selected. |
| Standalone Markdown | CommonMark text with optional small front matter. | `DocumentBook` with converted HTML, heading navigation, and selected metadata. |
| RTF | Grouped rich text with control words and optional `info` metadata. | `DocumentBook` with readable text, basic emphasis, title, and author. |
| TXTZ | A ZIP archive containing text documents and optional metadata or cover files. | `DocumentBook` with the ordered text documents converted to HTML and their extracted resources. |
| HTML | One HTML document. | A `DocumentBook` that preserves the decoded source HTML while normalizing its path and deriving metadata and heading navigation. |
| HTMLZ | A ZIP archive with a top-level HTML file and optional OPF metadata. | `DocumentBook` with the HTML entry point and its resources. |
| DOCX | A ZIP package of WordprocessingML XML parts. | Reflowable HTML, extracted resources, metadata, and navigation. |
| ODT | A ZIP package defined by the OpenDocument format. | Reflowable HTML, extracted resources, metadata, and navigation. |
| FB2 and zipped FB2, often called FBZ | FictionBook XML with text structure and embedded Base64 resources. | `Fb2Book` with generated HTML sections, resources, metadata, and navigation. The ZIP inventory itself is not retained. |
| CBZ | A ZIP of comic page images, sometimes with `ComicInfo.xml`. | `ComicBook` with ordered image pages and optional comic metadata. |
| CBR | A RAR archive of comic page images. | The same `ComicBook` model as CBZ. |
| CB7 | A 7-Zip archive of comic page images. | The same `ComicBook` model, opened asynchronously. |
| CBC | A ZIP collection that lists nested comics in `comics.txt`. | One flattened `ComicBook` whose pages follow collection order. |

The detector explicitly rejects Amazon Topaz and Amazon KFX. An encrypted PDF can open when the caller supplies a supported password. Kindle DRM and unsupported PDF security handlers fail with an owned exception. Markdown needs a path extension or an explicit format-specific call because it has no byte signature.

## Start with the public API

The files at the root of `lib/` define what package consumers can import. They do not implement parsing.

| File | What it exposes |
| --- | --- |
| `lib/unseal.dart` | The main format-neutral API. It exports every supported parser family, shared book types, detection, reading helpers, search, annotations, locators, CFI, OPDS, Calibre, text policies, and reader facades. |
| `lib/epub.dart` | EPUB parsing, EPUB entities, structural diagnostics, metadata updates, media-overlay structure, and shared book entities. |
| `lib/mobi.dart` | MOBI and AZW3 parsing, MOBI entities and exceptions, and shared book entities. |
| `lib/azw4.dart` | AZW4 extraction and parsing plus the `PdfBook` result type. |
| `lib/pdf.dart` | PDF parsing, PDF entities and exceptions, and shared book entities. |
| `lib/djvu.dart` | DjVu JPEG, bounded JB2, and bounded IW44 page parsing, page data, typed failures, and shared book entities. |
| `lib/tiff.dart` | TIFF and BigTIFF page parsing, the `TiffBook` model, typed failures, and shared book entities. |
| `lib/chm.dart` | CHM topic, resource, navigation, and metadata parsing. |
| `lib/docx.dart` | DOCX parsing and DOCX exceptions. |
| `lib/odt.dart` | ODT parsing and ODT exceptions. |
| `lib/fb2.dart` | FB2 parsing, FB2 entities and exceptions. |
| `lib/html.dart` | HTML and HTMLZ parsing through the small public wrapper in the HTML feature. |
| `lib/txt.dart` | TXT and TXTZ parsing and metadata reading. It deliberately hides archive-level helpers. |
| `lib/markdown.dart` | Standalone Markdown parsing and metadata reading. |
| `lib/rtf.dart` | RTF parsing and metadata reading. |
| `lib/palmdoc.dart` | PalmDOC PDB parsing and metadata reading. |
| `lib/ereader.dart` | Unencrypted eReader PDB text and metadata reading. |
| `lib/plucker.dart` | Plucker PDB text and metadata reading. |
| `lib/lrf.dart` | Sony BBeB/LRF parsing and metadata reading. |
| `lib/lrx.dart` | LRX2 plaintext metadata reading; DRM-protected book content rejection. |
| `lib/comic.dart` | CBZ and CBR parsing, comic entities and exceptions. |
| `lib/comic7.dart` | CB7 and CBC parsing while reusing the common `ComicBook` model. |

Read `lib/unseal.dart` first when reviewing public compatibility. An item exported there becomes part of the normal consumer contract. A file under `lib/src/` stays internal unless an entry point exports it.

## Foundation: the language shared by all formats

`lib/src/foundation/` contains values and policies used by multiple independent features. It does not contain a half-finished format parser. A format-specific rule stays with its format even when the implementation is large.

### Book and file entities

| File | What it does and why it exists |
| --- | --- |
| `foundation/entities/book/book.dart` | Defines the base `Book` contract and derives statistics and a default reading order from extracted HTML. Every parser returns a subtype of this contract. |
| `foundation/entities/book/document_book.dart` | Holds the common result of formats converted to HTML. It adds an optional cover, archive inventory, and explicit order without making each document format invent a book class. |
| `foundation/entities/book/reading_order_item.dart` | Names one item in reading order and records whether it is HTML. Comics use non-HTML items. |
| `foundation/entities/book/files.dart` | Groups images, CSS, HTML, fonts, and remaining binaries so consumers do not inspect format-owned containers. |
| `foundation/entities/book/archive_entry.dart` | Records a physical archive member's path and size without keeping its expanded bytes. This supports inventory and diagnostics. |
| `foundation/entities/file/book_file.dart` | Defines the shared identity of an extracted file: name, extension-like type, and path. The `type` value is normally `jpg`, `xhtml`, or `css`, not a MIME type. |
| `foundation/entities/file/text_file.dart` | Stores text content and exposes markup-free, whitespace-collapsed plain text. Parsers use it for HTML and CSS. |
| `foundation/entities/file/binary_file.dart` | Stores byte content for images, fonts, and other binary resources. |
| `foundation/entities/navigation/navigation.dart` | Defines the common table-of-contents root. |
| `foundation/entities/navigation/nav_point.dart` | Defines one table-of-contents node, including its label, target, ordering, and children. |
| `foundation/entities/book_metadata.dart` | Defines the format-neutral metadata record and computed sort keys. Every parser maps native metadata into this type. |
| `foundation/entities/book_cover.dart` | Stores cover bytes and the detected `ImageType`; the filename extension and MIME type are derived from that image format. |
| `foundation/entities/book_format.dart` | Lists the concrete source formats represented after parsing. |
| `foundation/entities/book_statistics.dart` | Computes word count and estimated reading time from each HTML file's collapsed `plainText` once per book. Stable character positions use a different text view. |
| `foundation/entities/entities.dart` | Re-exports the foundation entity files as one internal and public convenience entry point. |

### Shared policies

| File | What it does and why it exists |
| --- | --- |
| `foundation/archive/archive_access.dart` | Normalizes archive paths, resolves relative references, finds entries case-insensitively where appropriate, and converts archive content to bytes. It keeps ZIP path quirks out of each parser. |
| `foundation/files/book_file_factory.dart` | Creates `BinaryFile` and `TextFile` values with consistent names, paths, and inferred types. |
| `foundation/images/cover_helpers.dart` | Selects a fallback image cover and converts a `BinaryFile` into `BookCover`. |
| `foundation/images/image_dimensions.dart` | Reads dimensions from supported image headers without decoding a full bitmap. |
| `foundation/images/image_type_sniffer.dart` | Identifies common image formats from their bytes. Comic and document parsers use it instead of trusting file extensions. |
| `foundation/language/rtl_languages.dart` | Identifies right-to-left language codes for reading-direction decisions. |
| `foundation/metadata/book_metadata_operations.dart` | Merges metadata sources and applies a filename fallback. It centralizes precedence when a sidecar and the book disagree. |
| `foundation/metadata/series_index.dart` | Parses plain numeric series positions such as `2`, `2.5`, or `0,5` after trimming and decimal-separator normalization. Decorated values such as `Volume 2` are not accepted. |
| `foundation/metadata/sort_keys.dart` | Builds stable author sorting values and removes bracketed qualifiers when the policy requires it. |
| `foundation/metadata/title_sort.dart` | Moves leading articles according to language so titles sort consistently. |
| `foundation/spatial/spatial_rect.dart` | The shared rectangle in the canonical top-left page space; doubles because ALTO stores floats, exact for integer sources. |
| `foundation/spatial/spatial_unit.dart` | The unit vocabulary both positioned-text formats use (the ALTO enumeration): pixel self-verifies, physical units need a positive dpi and return null otherwise. |
| `foundation/spatial/spatial_text_zone.dart` | Region/line/word zones — the hierarchy levels DjVu hidden text and ALTO share — each with a rectangle, a UTF-16 range, and optional OCR confidence. |
| `foundation/spatial/spatial_text_page.dart` | One page of positioned text: depth-first region>line>word zones validated by an open-level stack, with provenance (native vs imported OCR, software, confidence presence). |
| `foundation/spatial/spatial_zone_lookup.dart` | Range queries over one page's zones: which word/line/region holds an offset, which zones overlap a range, which regions a selection paints. |
| `foundation/text/canonical_document_text.dart` | Scans and memoizes HTML into the whitespace-preserving character stream used by search, progression, navigation, locators, and annotations. Its shared `documentTextProfile` identifies that extraction contract. |
| `foundation/text/publication_revision.dart` | Defines the evidence-qualified publication identity (`PublicationRevision`, `SourceEvidence`) the common text contract binds snapshots to: namespaced opaque ids, `sha256` versus host versus unverified revisions, mutually exclusive by construction. |
| `foundation/text/section_occurrence.dart` | Defines one reading-order position: zero-based section index, exact parser path (repeats stay distinct), and the reading-order digest. |
| `foundation/text/text_profile.dart` | Defines the extraction profile (algorithm, options, plan revision) whose digest is the profile id, so two reading modes with different plans never share a text revision by convention. |
| `foundation/text/canonical_text_snapshot.dart` | Captures materialized section text bound to identity, occurrence, profile, and the derived UTF-16 text revision; the identity tuple compares every field including explicit nulls. |
| `foundation/text/canonical_text_range.dart` | Binds inclusive-start/exclusive-end UTF-16 bounds to one snapshot and validates them against it. |
| `foundation/text/revision_digest.dart` | Computes every contract digest: SHA-256 over little-endian UTF-16 code units (no BOM, no normalization, isolated surrogates preserved), with the platform-identical compact JSON serializer. Pinned vectors run on the VM and in Chrome. |
| `foundation/text/snapshot_codec.dart` | Encodes and decodes snapshots and ranges, recomputing every digest on import, refusing non-exportable identities, and normalizing hostile payloads to `CanonicalTextCodecException`; confirmed identity mismatches surface as `IncompatibleRevisionException`. |
| `foundation/text/html_escape.dart` | Escapes text before parsers insert it into generated HTML. |
| `foundation/text/plain_text.dart` | Removes tags, scripts, styles, and comments from HTML, decodes entities, and collapses whitespace into readable plain text. |
| `foundation/text/plain_text_writer.dart` | Implements the stateful whitespace and block-boundary rules used by plain-text extraction. |
| `foundation/text/word_count.dart` | Counts words in normalized text for statistics. |
| `foundation/text/xml_encoding.dart` | Detects BOMs and XML encoding declarations, then decodes XML bytes. This is necessary because FB2, OPF, and office XML are not always UTF-8. |
| `foundation/text/xml_encoding_tables.dart` | Holds the single-byte character tables used by `xml_encoding.dart`. Data stays separate from decoding control flow. |
| `foundation/exceptions/unseal_exception.dart` | Defines package-wide errors for unsupported formats, invalid books, and DRM-protected input. Format modules add more specific subclasses. |

Reading heuristics are separate, opt-in policies rather than part of format detection:

| File | What it does and why it exists |
| --- | --- |
| `lib/src/heuristics.dart` | Exposes the package-wide heuristics API. |
| `heuristics/chapter_detection.dart` | Finds likely chapter headings in imported plain text. |
| `heuristics/punctuation_normalization.dart` | Converts plain quotes, double hyphens, and three dots into typographic punctuation. |
| `heuristics/text_normalization.dart` | Normalizes scene breaks and joins hard-wrapped lines. |

### Two text views with different jobs

`TextFile.plainText` removes markup and collapses whitespace. `Book.statistics` uses that text because word count does not need stable DOM offsets.

`documentTextOf` preserves the visible character space inside the document body. Search, progression, navigation anchors, CFI, locators, and annotations use that text because a character offset must keep the same meaning across those capabilities.

Do not replace one operation with the other because their output looks similar in a small example. The difference is part of the position contract.

## Detection: identify the family before parsing

Detection answers "what kind of bytes are these?" It does not construct a book. ZIP needs a second step because the same container can hold EPUB, DOCX, ODT, FB2, HTMLZ, TXTZ, CBZ, or CBC.

The flow is:

`bytes -> detectFormat -> DetectedFormat -> BookDispatch -> concrete BookFormat`

For ZIP, `BookDispatch` checks internal evidence in order: EPUB, CBC, FB2, DOCX, ODT, HTMLZ, TXTZ, then image-based CBZ. The order prevents a generic ZIP fallback from stealing a package with stronger identifying files.

| File | What it does and why it exists |
| --- | --- |
| `features/detection/entities/detected_format.dart` | Defines broad families recognized from bytes. These values are intentionally less specific than `BookFormat` when deeper inspection is required. |
| `features/detection/detect_format.dart` | Checks signatures and bounded content for PDF, DjVu, TIFF/BigTIFF, ZIP, 7-Zip, RAR, Palm Database, RTF, FB2, HTML, and text. It also rejects known unsupported families with clear errors. |
| `features/detection/refine_mobi_format.dart` | Opens enough of a Palm Database header to distinguish legacy MOBI from KF8 or AZW3 after broad detection. |

## Reading: select a parser and resolve reading positions

| File | What it does and why it exists |
| --- | --- |
| `features/reading/book_dispatch.dart` | Owns the central mapping from detected families to parsers. It also opens ZIP once and distinguishes EPUB, FB2, DOCX, ODT, HTMLZ, TXTZ, CBC, and CBZ by internal evidence. |
| `features/reading/book_inspection.dart` | Holds the result of a full open: the parsed book on success or the original typed failure on rejection. Its detected family is only a signature hint. |
| `features/reading/book_progression.dart` | Calculates section and whole-book fractions from a section and character position. It lets consumers express progress without knowing each format's storage. |
| `features/reading/nav_resolution.dart` | Resolves `NavPoint.content` strings into typed targets aligned with a book's reading order. It handles paths, fragments, MOBI `filepos` targets, and malformed or missing destinations. It does not resolve comic or PDF page numbers. |

`BookDispatch` is intentionally central. Without it, every reader facade would duplicate a growing series of format checks. The individual parsers remain independent and do not choose one another, except where one format truly wraps another, such as AZW4 wrapping PDF.

### Why several parser folders use Dart `part` files

TXT, DOCX, ODT, and FB2 split their implementation with Dart's `part` and `part of` directives. In each case, `parse_<format>_book.dart` is the library. The part files are not independently importable modules, and their private names remain visible to one another because Dart compiles them as one library.

The folders still matter: they let a reader find package access, metadata, rendering, and resources without scrolling through one very large file. They are reading boundaries inside one implementation, not runtime interfaces.

## TXT and TXTZ: create structure from plain text

TXT has no formal metadata, resource manifest, or table of contents. unseal must decode the bytes, apply bounded conventions, and produce one safe HTML document. TXTZ adds a ZIP container around that text and may include metadata or a cover.

The flow is:

`bytes -> decode text -> read optional header -> render paragraphs and headings -> DocumentBook`

| File | What it does and why it exists |
| --- | --- |
| `features/txt/parse_txt_book.dart` | Coordinates TXT and TXTZ parsing, encoding fallback, size limits, metadata conventions, ordered documents, covers, resources, navigation, and final `DocumentBook` construction. |
| `features/txt/text/txt_document.dart` | Turns plain text, a limited Markdown subset, or a limited Textile subset into safe HTML and derives navigation from headings. Rendering rules stay separate from archive selection. |
| `features/txt/archive/txtz_archive.dart` | Validates archive limits and paths, orders text entries naturally, reads optional metadata, and returns the validated archive contents. `parse_txt_book.dart` later classifies resources. |

Plain TXT becomes paragraphs with one navigation point. Headings are recognized only when the caller explicitly selects the supported Markdown or Textile input mode. The separate, opt-in policies in `lib/src/heuristics.dart` are not applied by `parseTxtBook`.

## Standalone Markdown, RTF, and PalmDOC

These formats turn source text into the same `DocumentBook` reading contract while
keeping their own format identity. Markdown bytes have no unique signature, so
`Unseal.readFile` recognizes `.md`, `.markdown`, and `.mdown`; callers with
bytes use `parseMarkdownBook` directly. RTF has a byte signature. PalmDOC is
identified by a `TEXt/REAd` Palm Database without a MOBI header.

| File | What it does and why it exists |
| --- | --- |
| `features/markdown/parse_markdown_book.dart` | Converts CommonMark to HTML, reads bounded simple front matter, assigns heading targets, and builds navigation. Relative resources remain references because byte input cannot access neighboring files. |
| `features/rtf/parse_rtf_book.dart` | Reads bounded RTF groups and control words, skips non-reading destinations, decodes text and metadata, and emits paragraphs with basic character emphasis. |
| `features/palmdoc/parse_palmdoc_book.dart` | Validates PalmDOC record zero, decompresses bounded independent text records, and reuses the TXT converter for plain reading text. |
| `features/ereader/parse_ereader_book.dart` | Recognizes eReader record-zero variants, rejects DRM, expands bounded text and resource records, converts supported PML into reading-oriented HTML, and reads metadata. |
| `features/plucker/parse_plucker_book.dart` | Validates the Plucker index and paragraph tables, expands bounded DOC or zlib text records, joins continued fragments, and renders supported inline styles and paragraph links. |
| `features/plucker/plucker_bitmap.dart` | Converts bounded, uncompressed Palm 1/2/4-bit grayscale, 8-bit standard or custom palettes, and 16-bit RGB565 direct-color rows to PNG. Internally compressed bitmaps and other Palm bitmap variants fail with typed errors. |
| `features/lrf/parse_lrf_book.dart` | Reads BBeB object indexes, expands bounded streams, converts ordered text objects, and exposes metadata, navigation, and images. |

## HTML and HTMLZ: preserve an existing document

Standalone HTML already contains document structure. HTMLZ packages a top-level HTML file and its assets in ZIP. Some HTMLZ books also include an OPF file with richer metadata.

The flow is:

`HTML bytes or HTMLZ archive -> decode DOM -> normalize paths and inspect headings -> collect metadata/resources -> DocumentBook`

| File | What it does and why it exists |
| --- | --- |
| `features/html/html.dart` | Re-exports the HTML exception and parsing operations as the feature's internal barrel. |
| `features/html/parse_html_book.dart` | Coordinates standalone HTML and HTMLZ, chooses the archive entry point, merges HTML and OPF metadata, extracts resources, and builds `DocumentBook`. |
| `features/html/parsing/html_document.dart` | Decodes the HTML document, preserves that decoded HTML in a `TextFile`, normalizes its file path, and derives navigation from heading elements. It does not sanitize or rewrite the DOM. |
| `features/html/metadata/html_metadata.dart` | Reads title, authors, description, language, identifiers, and cover hints from HTML and optional OPF structures. |
| `features/html/exceptions/html_exception.dart` | Reports HTMLZ failures such as an invalid ZIP, a missing root HTML entry, or an empty selected entry. Standalone HTML parsing is intentionally tolerant. |

## DOCX: translate WordprocessingML into HTML

A DOCX file is a ZIP package. Its main document, styles, numbering, relationships, metadata, fonts, and images live in separate XML parts. Relationship identifiers connect document elements to resources.

The flow is:

`ZIP -> required DOCX parts -> relationships/styles/numbering -> XHTML -> resources -> DocumentBook`

| File | What it does and why it exists |
| --- | --- |
| `features/docx/parse_docx_book.dart` | Coordinates the package reader, metadata, relationships, styles, numbering, renderer, resources, cover fallback, and final `DocumentBook`. |
| `features/docx/container/docx_package.dart` | Validates the ZIP as DOCX and locates required and optional XML parts. It hides package paths from the rest of the feature. |
| `features/docx/container/docx_relationships.dart` | Maps Word relationship identifiers to normalized targets such as images and hyperlinks. |
| `features/docx/metadata/docx_metadata.dart` | Reads the core-properties XML into `BookMetadata`. |
| `features/docx/styles/docx_styles.dart` | Interprets named styles and numbering definitions used while rendering paragraphs and lists. |
| `features/docx/rendering/docx_renderer.dart` | Walks WordprocessingML and emits XHTML plus navigation. It handles paragraphs, runs, headings, lists, tables, external links, images, breaks, and basic inline formatting. Footnotes and endnotes are not implemented. |
| `features/docx/resources/docx_resources.dart` | Extracts referenced images, fonts, and remaining package files into `Files`. The first extracted image becomes the cover fallback, which can be a logo rather than a true cover. |
| `features/docx/exceptions/docx_exception.dart` | Defines DOCX errors for invalid packages, missing parts, and malformed XML. |
| `features/docx/exceptions/exceptions.dart` | Re-exports the public DOCX exception types. |

DOCX separates relationships and rendering because an image element does not contain an image path. It contains an identifier that only the relationships part can resolve.

## ODT: translate OpenDocument XML into HTML

An ODT file is also a ZIP package, but its XML vocabulary differs from DOCX. `content.xml` stores the document, `styles.xml` stores reusable styles, and `meta.xml` stores metadata.

The flow is:

`ZIP -> ODT package -> style catalog -> XHTML -> resources -> DocumentBook`

| File | What it does and why it exists |
| --- | --- |
| `features/odt/parse_odt_book.dart` | Coordinates metadata, styles, rendering, resources, cover selection, and final `DocumentBook`. |
| `features/odt/container/odt_package.dart` | Validates the package and provides access to the archive plus parsed `content.xml`, `styles.xml`, and `meta.xml`. It does not interpret `META-INF/manifest.xml`. |
| `features/odt/metadata/odt_metadata.dart` | Reads Dublin Core and OpenDocument metadata into `BookMetadata`. |
| `features/odt/styles/odt_styles.dart` | Resolves named and automatic styles into the properties needed by the renderer. |
| `features/odt/rendering/odt_renderer.dart` | Converts OpenDocument paragraphs, headings, lists, tables, spans, links, and images into XHTML and navigation. |
| `features/odt/resources/odt_resources.dart` | Extracts images, fonts, and other files from the package. The first extracted image becomes the cover fallback, so an early logo can be selected instead of a title-page image. |
| `features/odt/exceptions/odt_exception.dart` | Defines ODT errors for invalid packages, missing parts, and malformed XML. |
| `features/odt/exceptions/exceptions.dart` | Re-exports the public ODT exception types. |

DOCX and ODT use similar folder names because both need package access, styles, resources, metadata, and rendering. They do not share their XML interpretation because the formats define different rules.

## FB2 and FB2.zip: turn semantic XML into reading documents

FictionBook 2 stores the book as XML. Unlike DOCX, its elements describe book concepts such as sections, epigraphs, poems, and authors. Binary images can appear inside the XML as Base64 text. FB2.zip wraps an FB2 file in ZIP without changing the document model.

The flow is:

`XML bytes or ZIP entry -> decoded FB2 document -> embedded resources and metadata -> section XHTML -> Fb2Book`

| File | What it does and why it exists |
| --- | --- |
| `features/fb2/parse_fb2_book.dart` | Coordinates byte or archive input, XML parsing, resources, metadata, body conversion, and `Fb2Book` construction. |
| `features/fb2/container/fb2_document.dart` | Decodes the source XML, validates the FictionBook root, and exposes the root and body elements. Metadata code finds the description from that root. |
| `features/fb2/metadata/fb2_metadata.dart` | Maps FB2 title information, authors, language, genres, sequence, identifiers, dates, publisher data, and cover reference into `BookMetadata`. |
| `features/fb2/resources/fb2_resources.dart` | Decodes embedded Base64 binaries, classifies images, and resolves the cover. |
| `features/fb2/rendering/fb2_html_renderer.dart` | Converts FB2 bodies and semantic elements into HTML files, CSS, and navigation. |
| `features/fb2/entities/fb2_book.dart` | Defines the specialized book result for FB2 content. |
| `features/fb2/entities/entities.dart` | Re-exports the public FB2 entity types. |
| `features/fb2/exceptions/fb2_exception.dart` | Defines feature-owned FB2 parsing failures. |
| `features/fb2/exceptions/exceptions.dart` | Re-exports the public FB2 exception types. |

## EPUB: assemble a publication from a package

An EPUB is a ZIP package. `META-INF/container.xml` points to an OPF package document. The OPF lists resources in a manifest and lists reading order in a spine. EPUB 2 often stores navigation in NCX. EPUB 3 normally stores it in an HTML navigation document. Optional SMIL files synchronize text with prerecorded audio.

The flow is:

`ZIP -> root OPF path -> package model -> manifest files -> spine order -> navigation/cover/encryption -> EpubBook`

### Package and book model

| File | What it does and why it exists |
| --- | --- |
| `features/epub/parse_epub_book.dart` | Coordinates the complete EPUB parse. It locates and parses the OPF, reads navigation and encryption metadata, extracts files, finds the cover, calculates spine paths, and builds `EpubBook`. |
| `features/epub/epub_document.dart` | Defines the EPUB-specific document contract used by `EpubBook`, including its package, spine paths, page list, and landmarks. |
| `features/epub/entities/book/book.dart` | Implements `EpubBook` with the common `Book` values plus the parsed package, explicit spine, navigation sections, and archive inventory. |
| `features/epub/entities/book/epub_landmark.dart` | Preserves a landmark's label, destination, and semantic `epub:type` tokens. |
| `features/epub/entities/entities.dart` | Re-exports the public EPUB entity files. |
| `features/epub/container/epub_root_file.dart` | Reads `container.xml` to find the OPF path and provides a recovery scan for real books with missing or broken container metadata. |
| `features/epub/diagnostics/epub_diagnostic.dart` | Defines the diagnostic finding, severity, bounded options, and report types for EPUB structural diagnostics. |
| `features/epub/diagnostics/diagnose_epub.dart` | Runs the bounded structural diagnosis: mimetype, container and rootfile selection with recovery, manifest, spine, EPUB 2/3 navigation links and fragments, and guide references. It changes no reading outcome. |
| `features/epub/package/parse_epub_package.dart` | Parses OPF XML into an EPUB 2 or EPUB 3 package model, including metadata, manifest, spine, guide, and refinements. |
| `features/epub/entities/package/epub_package.dart` | Defines the shared package data: metadata, manifest items, spine references, and guide references. |
| `features/epub/entities/package/epub_2_package.dart` | Stores EPUB 2 metadata and adapts its older OPF rules to the shared package interface. |
| `features/epub/entities/package/epub_3_package.dart` | Stores EPUB 3 metadata, refinements, and typed rendition and accessibility views under the shared package interface. |
| `features/epub/entities/package/epub_rendition.dart` | Models publication-wide display preferences and per-spine-item overrides from the OPF. It does not read page dimensions from XHTML or SVG. |
| `features/epub/entities/package/epub_accessibility.dart` | Groups publisher-declared access modes, sufficient alternatives, features, hazards, and summaries for discovery. It does not certify accessibility. |
| `features/epub/entities/package/page_progression_direction.dart` | Represents left-to-right, right-to-left, and `unspecified` page progression. A missing, invalid, or OPF `default` value becomes `unspecified`. |

### Content, metadata, and navigation

| File | What it does and why it exists |
| --- | --- |
| `features/epub/content/epub_files.dart` | Resolves manifest paths, decodes text, classifies resources, and undoes declared IDPF or Adobe obfuscation only for font resources. Unknown encryption algorithms make the EPUB unsupported. |
| `features/epub/metadata/epub_metadata.dart` | Maps the version-specific package metadata and optional cover into `BookMetadata`. |
| `features/epub/metadata/epub_cover.dart` | Applies EPUB 2 and EPUB 3 cover conventions, resolves the chosen manifest item, and reads its image bytes. |
| `features/epub/metadata/epub_metadata_writer.dart` | Updates selected metadata fields inside an existing EPUB and writes a new ZIP while preserving unrelated entries. |
| `features/epub/navigation/epub_navigation.dart` | Converts EPUB 3 navigation HTML or NCX into common `Navigation` values. EPUB 3 prefers its nav document for the table of contents and falls back to NCX; EPUB 2 continues to prefer NCX. Page lists and landmarks remain separate from the table of contents. |
| `features/epub/codec/epub_xml.dart` | Uses the EPUB-specific decoder for UTF-8 or UTF-16, rejects UTF-32, and parses the result into XML nodes. It does not use the broader foundation XML decoder. |

### Encryption and media overlays

| File | What it does and why it exists |
| --- | --- |
| `features/epub/encryption/epub_encryption.dart` | Reads `META-INF/encryption.xml`, handles supported font obfuscation, and distinguishes obfuscation from unsupported DRM. |
| `features/epub/media_overlays/media_overlay.dart` | Defines timed text and audio segments parsed from SMIL. It describes synchronization but does not play audio. |
| `features/epub/media_overlays/parse_media_overlay.dart` | Parses SMIL sequences, parallel text/audio nodes, clip times, and relative resource references into `MediaOverlayDocument`. |
| `features/epub/media_overlays/parse_smil_clock.dart` | Parses full, partial, and unit-based SMIL clock values into durations. |
| `features/epub/exceptions/epub_exception.dart` | Defines EPUB failures with archive and package context. |
| `features/epub/exceptions/empty_bytes_exception.dart` | Gives `EpubBook.fromBytes` a clear empty-input failure. `BookDispatch` performs its own empty check; the lower-level `parseEpubBook` function calls the ZIP decoder directly. |
| `features/epub/exceptions/exceptions.dart` | Re-exports the public EPUB exception types. |

The package model preserves manifest, spine, guide, and EPUB metadata that do not fit in `BookMetadata`. File extraction, navigation, cover selection, and encryption can therefore share one interpretation of the OPF. EPUB 3 rendition preferences come from OPF metadata and spine properties; accessibility values are publisher declarations. `updateEpubMetadata` is a separate writer that reopens the ZIP and edits OPF XML directly. Media-overlay links stay in the package model, while `parseMediaOverlay` interprets an individual SMIL document. The narration package owns playback.

## Why metadata-only APIs are separate

Catalog screens often need a title and cover without paying the full cost of rendering every chapter. The metadata paths deliberately do less work, but they still perform enough validation to avoid describing unrelated bytes as a book:

| Format | What metadata-only reading actually does |
| --- | --- |
| TXT | Reads at most the first 64 KiB for the supported header convention and filename fallback. |
| TXTZ | Opens and validates the ZIP, then inspects OPF metadata or the first text document without rendering every document. |
| HTML | Decodes the standalone document and inspects its DOM. |
| HTMLZ | Selects the root HTML and optional OPF and may load a cover, but does not classify every resource. |
| DOCX | Requires valid `word/document.xml` before accepting metadata from `docProps/core.xml`. |
| ODT | Requires valid `content.xml` before using optional `meta.xml`. |
| FB2 | Tries a bounded fast path over `<description>` and the referenced cover `<binary>`, then falls back to the complete DOM when that slice is not trustworthy. |
| EPUB | Reads the OPF and, at most, the cover rather than inflating all publication resources. |

These paths may look like partial duplicates of full parsing, but they have a different cost contract. Removing one can make a library listing parse entire books merely to show metadata.

## Required content and optional degradation

Not every malformed optional file should make the whole publication unreadable. Each feature draws that boundary differently:

| Format | Fatal condition | Optional degradation |
| --- | --- | --- |
| TXTZ | No text document, unsafe path, or archive limit violation. | Invalid OPF metadata is ignored. |
| HTMLZ | No usable root HTML document. | Invalid OPF metadata is ignored. |
| DOCX | Missing or invalid `word/document.xml`. | Missing or invalid relationships, styles, numbering, or core properties are ignored. |
| ODT | Missing or invalid `content.xml`. | Invalid `meta.xml` or `styles.xml` is ignored. |
| FB2 | Wrong root element or no body. | An invalid Base64 binary is skipped individually. |
| EPUB | No valid OPF or an unknown encryption algorithm. | Missing or broken navigation becomes an empty `Navigation`. |

## CBZ and CBR: read a comic as ordered images

CBZ and CBR use archive formats as envelopes for page images. CBZ uses ZIP. CBR uses RAR. `ComicInfo.xml` can provide descriptive metadata, an explicit right-to-left direction, and page roles. Page order comes from filenames. A declared `FrontCover` becomes the cover; otherwise the first sorted image does.

The flow is:

`ZIP or RAR -> entries -> ComicInfo.xml and image pages -> natural filename order -> ComicBook`

| File | What it does and why it exists |
| --- | --- |
| `features/comic/parse_comic_book.dart` | Detects ZIP versus RAR, reads entries, parses `ComicInfo.xml`, keeps image files, sorts pages, and builds the common `ComicBook`. |
| `features/comic/natural_page_sort.dart` | Compares page names so numeric runs sort as readers expect, such as page 2 before page 10. |
| `features/comic/entities/comic_book.dart` | Defines the fixed-layout comic result, image files, page reading order, metadata, direction, and aligned page declarations. Its structured navigation is empty because comic archives rarely declare chapters. |
| `features/comic/entities/comic_page_info.dart` | Defines typed page roles and ComicInfo hints such as double-page spreads. Unknown role tokens stay available to callers. |
| `features/comic/entities/entities.dart` | Re-exports the public comic entity types. |
| `features/comic/metadata/comic_info.dart` | Reads descriptive fields, `Manga=YesAndRightToLeft`, and indexed `<Page>` attributes. Invalid or out-of-range page declarations do not shift image indices. |
| `features/comic/archive/rar_reader.dart` | Reads RAR headers and stored entries, decodes compressed RAR 4 and RAR 5 streams, and verifies declared RAR 5 checksums. |
| `features/comic/archive/rar5_archive.dart` | The shared RAR 5 container walk: header CRC verification, bounded vints, UTF-8 names, extra-area records, and the typed out-of-subset classification. |
| `features/comic/archive/rar5_decoder.dart` | The RAR 5 LZ/Huffman decompressor (algorithm version 0, methods 1-5, filters), a bounded adaptation of rardecode. `Rar5SolidDecoder` carries the dictionary — window, Huffman tables, recent offsets, filter queue — across a solid chain, and can snapshot and restore it for session checkpoints. |
| `features/comic/archive/rar4_method29_decoder.dart` | Implements the shared bit, Huffman, distance, and copy state machines for supported RAR method-29 compression. |
| `features/comic/archive/rar_random_access.dart` | Exposes the RAR entry source used by progressive CBR sessions: one solid decoder, checkpoint set, and cumulative replay budget per session. |
| `features/comic/exceptions/comic_exception.dart` | Reports invalid archives, unsupported RAR methods, and missing image pages. |
| `features/comic/exceptions/exceptions.dart` | Re-exports the public comic exception types. |

The RAR decoder is long because it implements a compression algorithm. Splitting tables and tightly coupled state into arbitrary small files would make the algorithm harder to follow. The useful boundary is between archive framing, decompression, metadata, ordering, and book construction.

Current CBR support is deliberately narrower than "any RAR." Stored RAR4 and RAR5 entries work. Common non-solid RAR4 method-29 compression works. RAR 5 compression works: algorithm version 0, methods 1-5, the delta / E8 / E8-E9 / ARM filters, UTF-8 names, header and data CRC-32 (a declared zero is a real checksum), dictionaries through 64 MiB, and solid chains — identical through the eager parse and sessions and byte-checked against the rardecode and libarchive oracles (`tool/rar5_compare.dart`). Split volumes, password protection, links, algorithm versions above 0, PPMd, and RAR virtual-machine filters reject typed with the entry name and reason.

Solid RAR 5 follows the reference decoder's semantics: the per-entry solid bit continues the carried dictionary, and each entry still owns a complete framed block stream, so decoding stays byte-aligned per entry. An out-of-subset compressed entry poisons later solid successors (typed as a broken chain dependency). Sessions decode forward in container order — the open sniff walks the whole chain, which is the documented sequential open cost — and serve backward accesses by replaying from bounded dictionary checkpoints under a cumulative replay budget; a failed decode poisons forward continuation until a checkpoint restore, and reopening resets every budget.

Comic page sniffing currently recognizes JPEG, PNG, GIF, BMP, and WebP bytes. RAR 5 headers verify their CRC-32 and RAR 5 declared data CRCs verify after decode; RAR 4 keeps its legacy rule of verifying non-zero declared CRCs only. RAR 5 names decode as UTF-8; RAR 4 names remain byte-for-byte. Natural sorting compares basenames first when pages sit at different folder depths, then uses full paths as a tiebreaker.

## CB7 and CBC: add 7-Zip comics and collections

CB7 stores comic pages in a 7-Zip archive. Opening 7-Zip is asynchronous in the selected dependency, so the normal synchronous parser cannot handle it. CBC is a ZIP collection. Its `comics.txt` file names nested comic archives and their optional titles.

The flow is:

`CB7 -> asynchronous 7-Zip reader -> ordered pages -> ComicBook`

`CBC -> comics.txt -> nested CBZ/CBR/CB7 books -> flattened pages -> ComicBook`

| File | What it does and why it exists |
| --- | --- |
| `features/comic7/parse_comic7_book.dart` | Opens and closes 7-Zip archives, reads CB7 pages and metadata, parses CBC listings, delegates nested comics to the matching parser, and combines their pages. |
| `features/comic7/exceptions/comic7_exception.dart` | Defines errors for unreadable 7-Zip input, missing CB7 pages, and invalid CBC collections. |
| `features/comic7/exceptions/exceptions.dart` | Re-exports the public CB7 and CBC exception types. |

CB7 reuses `ComicBook` because the reading result is still an ordered image sequence. It does not reuse the private ZIP or RAR implementation because 7-Zip has a different resource and lifetime model.

CBC flattens its children into one page list and shifts their page metadata indices with the pages. Conflicting child reading directions become `unspecified`; CBC does not preserve a chapter for each nested comic. A listing entry absent from the outer ZIP is skipped. A child that is present but cannot be parsed fails the collection. CB7 also caps each extracted entry at 128 MiB.

## MOBI and AZW3: rebuild a book from Palm Database records

MOBI is a family of binary formats used by older Kindle software. The outer file is a Palm Database, or PDB, split into numbered records. Record zero contains MOBI and EXTH headers. Later records contain compressed text, indexes, images, fonts, and other resources.

EXTH is an optional collection of numbered metadata records attached to the MOBI header. INDX, TAGX, and CNCX structures relate Kindle byte positions and records to tagged data and shared strings. Record trailers are bookkeeping bytes appended to compressed text chunks; the parser removes them before joining the chunks.

Legacy MOBI 6 stores HTML-like markup with `filepos` links, where the value is a byte position in the original markup rather than a file path. KF8, commonly named AZW3, stores XHTML skeleton templates and byte-range fragments that must be reassembled. Flow zero holds the main XHTML data; later flows commonly hold CSS or SVG. Some Kindle files contain both MOBI 6 and KF8. unseal chooses the KF8 half when it is present.

The flow is:

`PDB records -> MOBI/EXTH headers -> DRM check -> choose MOBI 6 or KF8 -> decompress text -> rebuild markup/resources/navigation -> MobiBook`

### Entry point and binary headers

| File | What it does and why it exists |
| --- | --- |
| `features/mobi/parse_mobi_book.dart` | Coordinates the entire format family. It parses headers, rejects DRM, resolves the payload layout, chooses the MOBI 6 or KF8 reader, and builds metadata and `MobiBook`. |
| `features/mobi/header/mobi_layout.dart` | Resolves the payload layout shared by the eager parse and sessions: standalone KF8, a joint file's BOUNDARY-marked KF8 half, or plain MOBI 6, plus the record-level cover lookup. |
| `features/mobi/entities/mobi_book.dart` | Defines the MOBI result, chapter representation, resources, navigation, and reading order. |
| `features/mobi/entities/entities.dart` | Re-exports the public MOBI entity types. |
| `features/mobi/header/pdb_header.dart` | Parses the Palm Database header and record table for MOBI, PalmDOC, eReader, and Plucker, then provides bounded access to numbered records. |
| `features/mobi/header/mobi_header.dart` | Parses PalmDOC and MOBI header fields that control compression, encoding, record counts, resources, indexes, and format version. |
| `features/mobi/header/exth_header.dart` | Parses optional EXTH metadata records used by Kindle for authors, identifiers, covers, KF8 boundaries, and other fields. |
| `features/mobi/codec/mobi_text_codec.dart` | Decodes MOBI text with the format's character encodings. |
| `features/mobi/codec/mobi_byte_search.dart` | Finds ASCII markers and byte patterns without mixing search logic into parsers. |
| `features/mobi/codec/mobi_bit_operations.dart` | Provides the small checked bit and integer operations shared by binary readers. |
| `features/mobi/codec/mobi_base32.dart` | Decodes the base-32 values used by MOBI structures. |

### Compression, indexes, and text

| File | What it does and why it exists |
| --- | --- |
| `features/mobi/compression/palmdoc.dart` | Decompresses the PalmDOC scheme used by many MOBI text records. |
| `features/mobi/compression/huff_cdic.dart` | Decodes MOBI's HUFF/CDIC dictionary compression with bit and phrase expansion logic. |
| `features/mobi/index/indx_reader.dart` | Reads Kindle INDX structures, tag tables, variable-width integers, and CNCX string tables into usable index maps. |
| `features/mobi/index/ncx_reader.dart` | Converts the Kindle NCX index into common navigation entries. |
| `features/mobi/reader/mobi_container.dart` | Decodes KF8 `CONT` and `CRES` image-container records, recognizes image metadata, removes the container prefix, and validates the remaining image bytes. |
| `features/mobi/reader/mobi_text.dart` | Reads text records, removes record trailers, applies the chosen decompressor, and concatenates the logical text stream. |
| `features/mobi/reader/mobi_text_store.dart` | The session-side record source: a random-access PalmDB over a byte source, and the decompressed text stream addressed by record spans. The open pass decompresses every text record once to build the record → stream-span index (decompressed sizes are undeclared), scanning bytes through an observer without retaining them; slices decompress only the covering records under a small LRU. |
| `features/mobi/reader/mobi6_sections.dart` | The MOBI 6 open-pass scanner and section planner: byte-level `filepos` targets, TOC anchor candidates, pagebreak fallbacks, and the document body range, then the section table with its global anchor insertion chain and target boundaries. |
| `features/mobi/reader/mobi8_session_scan.dart` | The KF8 open-pass scanner: flow classification flags (SVG/CDATA decisions mirroring the eager classifier) and quoted `kindle:pos:fid` reference discovery. |
| `features/mobi/reader/mobi_trailing_data.dart` | Removes variable trailing entries and multibyte overlap bytes described by MOBI record flags. |

### MOBI 6 and KF8 reconstruction

| File | What it does and why it exists |
| --- | --- |
| `features/mobi/reader/mobi6_markup.dart` | Repairs legacy markup, adds anchors for file-position links, extracts image resources, and derives basic navigation when needed. |
| `features/mobi/reader/mobi8_reader.dart` | Coordinates the KF8-specific indexes, text, structure, markup assembly, resources, fonts, and navigation. |
| `features/mobi/reader/mobi8_structure.dart` | Reads FDST, skeleton, fragment, and location indexes (`Mobi8Indexes`, record-only); inserts fragments into templates (`assembleMobi8Part`, shared with sessions); resolves Kindle positions and IDs; translates page breaks; and maps NCX positions to rebuilt parts. |
| `features/mobi/reader/mobi8_markup.dart` | Classifies secondary flows as CSS or SVG, and finalizes rebuilt parts through `Mobi8MarkupFinalizer` — pos:fid links, aid stripping, flow/embed rewrites, head normalization — the one implementation both the eager assembler and sessions route every part through. |
| `features/mobi/reader/mobi8_resources.dart` | Extracts images and fonts and builds the one-based Kindle embed-index map used while rewriting markup. |
| `features/mobi/reader/mobi_font.dart` | Decodes embedded Kindle font records, including supported obfuscation and compression. |
| `features/mobi/metadata/mobi_metadata.dart` | Maps MOBI and EXTH values, cover resources, and detected version into `BookMetadata`. |
| `features/mobi/metadata/mobi_language.dart` | Maps MOBI numeric language codes to language tags used by common metadata. |
| `features/mobi/exceptions/mobi_exception.dart` | Reports invalid PDB/MOBI structures, unsupported compression, malformed indexes, and related format failures. |
| `features/mobi/exceptions/exceptions.dart` | Re-exports the public MOBI exception types. |

MOBI support has intentional limits. The parser rejects DRM and unknown compression methods. Text decoding concentrates on UTF-8 and Windows-1252. MOBI 6 navigation chooses the longest useful sequence of `filepos` links when no useful NCX exists. KF8 reconstruction uses pattern-based markup rewriting rather than a complete DOM transformation; OTH and DATP information is not fully used, and ORDT handling is an approximate printable-character projection. Audio, video, and several control-record families are ignored. A font that cannot be decoded may remain as raw `.dat` bytes.

The metadata-only path does not call the full DRM rejection used when opening content. It can read descriptive header values from a protected envelope without claiming that unseal can open the book.

## AZW4: extract a PDF before parsing it

AZW4 is not another HTML-based Kindle format. It is a Palm Database wrapper around a PDF payload, with enough Kindle metadata to label the document.

The flow is:

`PDB container -> locate PDF records -> join PDF bytes -> PDF parser -> PdfBook tagged as AZW4`

| File | What it does and why it exists |
| --- | --- |
| `features/azw4/parse_azw4_book.dart` | Extracts the payload, delegates all PDF interpretation to `parsePdfBook`, applies AZW4 format and title metadata, and returns `PdfBook`. |
| `features/azw4/container/azw4_pdf_extractor.dart` | Validates PalmDB/MOBI structure when present, rejects wrapper DRM, prefers rebuilding the payload from records, and uses a bounded search for a complete `%PDF` through `%%EOF` range as recovery. It returns embedded PDF bytes plus the container title. |
| `features/azw4/exceptions/azw4_exception.dart` | Distinguishes invalid containers, missing PDF payloads, and DRM-protected AZW4 files. |

This is intentional reuse. AZW4 owns extraction because only AZW4 knows the wrapper. PDF owns pages, fonts, security, text, images, and reflow.

The outer input is capped at 512 MiB, and fallback searches only the first 32 MiB for the PDF start. Recovery can accept complete PDF-shaped bytes even when no valid PalmDB wrapper exists. `PdfBook.bytes` contains the embedded PDF, not the original AZW4 envelope. The PDF's own title wins; the wrapper title is only a fallback. Wrapper DRM fails before extraction, while the embedded PDF can independently require a PDF password.

## PDF: interpret a document object graph

A PDF does not store chapters as HTML. It stores numbered objects. Those objects describe page trees, fonts, drawing instructions, images, metadata, outlines, compression filters, and encryption. A cross-reference structure tells the reader where each object lives in the byte stream.

Text extraction is therefore reconstruction. The parser resolves objects, interprets page drawing commands, maps character codes through fonts, groups positioned glyphs into lines, and then creates reflowed HTML. The original PDF bytes remain in `PdfBook` so the Viewer can also offer page-faithful rendering.

The flow is:

`bytes -> objects and cross-references -> optional decryption -> page tree -> content streams and fonts -> canonical lines/images -> outline and metadata -> reflowed HTML -> PdfBook`

### Document syntax and public result

| File | What it does and why it exists |
| --- | --- |
| `features/pdf/parse_pdf_book.dart` | Coordinates document parsing, pages, metadata, outline, layout and image extraction, reflow, and final `PdfBook` construction; builds one page's `PdfPageStructure` on demand through `buildPdfPageStructure`. |
| `features/pdf/layout/pdf_page_structure.dart` | Aggregates one page's stable structure: source lines, words, blocks, columns, tables, the canonical text under its profile (scope plus plan revision), and the source-anchor mapping (`mapped`/`ambiguous`/`missing`/`unsupported`); also derives the page geometry's affine back to PDF user space and the plan revision digest. |
| `features/pdf/layout/pdf_layout_segmentation.dart` | Groups words into lines and blocks with the Docstrum bottom-up construction adapted to word components: nearest-neighbor orientation histogram over a half turn, transitive closure, vertical block merging. Bounded per page. |
| `features/pdf/layout/pdf_reading_order.dart` | Orders blocks with a recursive XY-cut: empty horizontal bands split regions, empty vertical gutters split columns (content blocks veto a split, editorial roles may cross them). |
| `features/pdf/layout/pdf_table_detector.dart` | Detects at most one table per page: ruling lattices (`spreadsheet`), vertical rulings plus text rows (`basic`), or the whitespace-aligned fallback (`aligned-columns`); every refusal is a typed diagnosis on `PdfTableUnsupported`. |
| `features/pdf/entities/pdf_layout.dart` | Defines the public layout model: `PdfPageGeometry` with the invertible page-to-user affine, `PdfWord`, `PdfRuleLine`, `PdfTextBlock` with editorial roles and source-line provenance, `PdfColumnRegion`, and the table cell/region/refusal types. |
| `features/pdf/entities/pdf_position.dart` | Defines the stable source-space anchors (`PdfSourceRange`) and the mapping outcome union with its reasons. |
| `features/pdf/header/pdf_object.dart` | Defines the PDF value model: null, booleans, numbers, names, strings, arrays, dictionaries, streams, and indirect references. |
| `features/pdf/header/pdf_object_parser.dart` | Tokenizes and parses PDF object syntax from bounded byte ranges. It knows syntax, not document navigation. |
| `features/pdf/header/pdf_document.dart` | Locates cross-reference tables or streams, reads trailers and object streams, resolves indirect references, caches objects, and connects the security handler. |
| `features/pdf/entities/pdf_book.dart` | Defines the parsed PDF result with original bytes, pages, extracted text, per-page layout extractions, images, reflowed page files, metadata, and navigation. |
| `features/pdf/entities/pdf_page.dart` | Stores one page's object number, geometry, rotation, crop box, and effective resources. |
| `features/pdf/entities/pdf_page_text.dart` | Stores canonical text lines, image placements, stream-decoding counts, and a per-page extraction diagnosis. It gives search, reflow, and facsimile selection one shared character-space contract. |
| `features/pdf/entities/entities.dart` | Re-exports the public PDF entity types, including the layout and position models. |
| `features/pdf/exceptions/pdf_exception.dart` | Defines general PDF failures and the more specific encrypted-document error. |
| `features/pdf/exceptions/exceptions.dart` | Re-exports the public PDF exception types. |

### Streams, pages, fonts, and visible content

| File | What it does and why it exists |
| --- | --- |
| `features/pdf/codec/pdf_stream_decoder.dart` | Applies PDF stream filter chains, including Flate, LZW, ASCII encodings, run-length, predictors, CCITT, and JBIG2. Unsupported filters throw `PdfException`; a caller may fail, recover, or retain only geometry depending on the stream's role. |
| `features/pdf/reader/pdf_page_tree.dart` | Walks the hierarchical page tree in reading order and applies inherited boxes, resources, and rotation safely. |
| `features/pdf/reader/pdf_content_stream.dart` | Interprets the graphics matrices, text state, text-showing commands, and image `Do` operations needed for extraction. Layout extraction (`extractLayout`) additionally records per-character glyph cells (absolute pen positions from real advances) and axis-aligned ruling segments from `re`/stroke paths, both bounded; it is not a general PDF renderer and does not process clipping, colors, shading, or Form XObject contents. |
| `features/pdf/reader/pdf_font.dart` | Resolves simple and composite fonts, maps encoded character codes to Unicode, and calculates glyph widths used for spacing and geometry. |
| `features/pdf/reader/pdf_cmap.dart` | Parses ToUnicode CMaps and code-space mappings used by composite fonts. Without this translation, many PDFs expose numeric glyph codes instead of text. |
| `features/pdf/reader/pdf_outline.dart` | Reads bookmarks and named destinations and maps them to page anchors in common `Navigation`. |
| `features/pdf/reader/pdf_metadata.dart` | Combines the Info dictionary and XMP metadata into `BookMetadata`. |
| `features/pdf/image/pdf_bitmap.dart` | Normalizes packed one-bit image rows and writes them as grayscale PNG for extracted CCITT and JBIG2 resources. |
| `features/pdf/reflow/pdf_reflow.dart` | Removes repeated headers and footers, conservatively reorders clearly separated text-only columns, groups lines into blocks, and emits one responsive HTML document per page. After deliberate header/footer removal, each returned page-text value matches the visible text scanned from that page's generated HTML. |
| `features/pdf/text/pdf_encodings.dart` | Holds Adobe encoding tables and glyph-name mappings used by simple fonts. This is primarily data, not parser orchestration. |
| `features/pdf/text/pdf_standard_widths.dart` | Holds metrics for the standard 14 PDF fonts when the document omits explicit widths. |

The repeated role of page geometry matters. A PDF text operator may say which glyph to draw and where to draw it, but it does not say "this is the second sentence of paragraph three." `PdfTextExtractor` and `PdfReflow` recover that reading structure.

### PDF security

| File | What it does and why it exists |
| --- | --- |
| `features/pdf/security/pdf_security_handler.dart` | Authenticates user or owner passwords, validates the standard security dictionary, derives file and object keys, and selects RC4 or AES behavior for supported revisions. |
| `features/pdf/security/pdf_object_decryptor.dart` | Recursively decrypts strings and streams for one indirect object while preserving reference and identity-filter rules. |
| `features/pdf/security/pdf_security_algorithm_2a.dart` | Authenticates revision 5 and 6 user or owner passwords and decrypts `/UE` or `/OE`. Revision 5 uses SHA-256; revision 6 uses the iterative 2.B derivation. |
| `features/pdf/security/pdf_crypto_primitives.dart` | Provides MD5, SHA-256, SHA-384, SHA-512, RC4, AES-CBC, and AES-ECB operations required by PDF security. |

Security code opens a document that the caller is authorized to read. It does not bypass DRM or certificate-based public-key security.

The handler accepts standard security versions `/V` 1 through 5 and revisions `/R` 2 through 6, including legacy RC4, V2, AESV2, AESV3, and identity crypt filters. It does not support public-key or certificate handlers. After successful authentication, unseal does not enforce or expose copy, print, or extraction permission flags. The revision 5/6 `/Perms` verification helper is present but is not called by the current authentication path.

### CCITT fax images

CCITT Group 3 and Group 4 are one-bit image compression schemes originally designed for fax. Scanned PDF pages often use them for black-and-white images.

The implementation covers Group 3 one-dimensional (`K = 0`), Group 3 two-dimensional (`K > 0`), and Group 4 (`K < 0`), together with the common columns, rows, polarity, byte-alignment, end-of-line, and end-of-block parameters.

| File | What it does and why it exists |
| --- | --- |
| `features/pdf/codec/ccitt/ccitt_decoder.dart` | Decodes CCITTFaxDecode streams into packed black-and-white rows and enforces limits for malformed dimensions or non-progressing input. |
| `foundation/images/ccitt/ccitt_tables.dart` | Stores the standard run-length and two-dimensional Huffman tables shared by CCITT and JBIG2 MMR decoding. |

### JBIG2 images

JBIG2 compresses black-and-white images as reusable symbols, text regions, generic regions, and halftone patterns. It is common in scanned documents and much more involved than decoding PNG or JPEG.

| File | What it does and why it exists |
| --- | --- |
| `features/pdf/codec/jbig2/jbig2_decoder.dart` | Reads JBIG2 segments, applies shared global segments, dispatches each supported segment type, composes page regions, and returns packed bitmap bytes. |
| `features/pdf/codec/jbig2/segment_decoder.dart` | Defines segment headers, region information, arithmetic integer procedures, and shared low-level readers. |
| `features/pdf/codec/jbig2/arithmetic_decoder.dart` | Implements the adaptive MQ arithmetic decoder used by many JBIG2 regions. |
| `features/pdf/codec/jbig2/huffman_decoder.dart` | Implements JBIG2 Huffman trees, standard and custom tables, symbol-ID tables, and table selection. |
| `features/pdf/codec/jbig2/mmr_decoder.dart` | Implements the Group 4 MMR path that JBIG2 can use for bitmap regions. It shares canonical CCITT tables. |
| `features/pdf/codec/jbig2/region_decoder.dart` | Decodes generic, refinement, symbol, text, pattern, and halftone regions into pixel rows. |

These codec files are algorithm modules. Their size comes from the standards, state machines, and lookup tables. Review them by input bounds, progress guarantees, parity tests, and output correctness, not by a generic line-count rule.

This is an implemented subset of JBIG2 rather than full standard parity. It rejects unsupported segment types and combinations such as refinement prediction, Huffman refinement paths, unsupported page/region composition operators, halftone skip, and nonzero halftone combination operators.

### JPEG 2000 images

JPEG 2000 (ISO/IEC 15444-1) appears in scanned and print-originated PDFs as
`JPXDecode` image streams. The port follows a pinned OpenJPEG revision and is
accepted against its decoded output, not merely structurally.

| File | What it does and why it exists |
| --- | --- |
| `features/pdf/codec/jpeg2000/jpx_codestream.dart` | Parses SOC/SIZ/COD/COC/QCD/QCC/SOT markers and JP2 boxes, enforcing the Part 1 subset and cross-checking wrapper geometry. |
| `features/pdf/codec/jpeg2000/jpx_tile.dart` | Computes resolution/precinct/code-block geometry, schedules tier-2 packets (LRCP/RLCP), assembles per-code-block segments, and runs dequantization, scatter, level shift, and clip. |
| `features/pdf/codec/jpeg2000/jpx_tier1.dart` | Decodes significance-propagation, magnitude-refinement, and cleanup passes over MQ segments with per-pass context reset and segmentation symbols. |
| `features/pdf/codec/jpeg2000/jpx_mq.dart` | The MQ arithmetic decoder with the reference's 32-bit code-register semantics shared by VM and compiled JS. |
| `features/pdf/codec/jpeg2000/jpx_tagtree.dart` | Inclusion and missing-significance-bits tag trees reusable across quality layers. |
| `features/pdf/codec/jpeg2000/jpx_dwt.dart` | The exact integer 5/3 lifting (with `toSigned(32)` shift normalization) and the float32 9/7 pipeline. |
| `features/pdf/codec/jpeg2000/jpx_mct.dart` | Inverse RCT and ICT component transforms. |
| `features/pdf/codec/jpeg2000/jpx_decoder.dart` | Tile assembly into planar 8-bit images, JP2 colorspace checks, and PNG encoding. |
| `features/pdf/codec/jpeg2000/jpx_limits.dart` | Every buffer budget (input, raster, tile buffers, components, tiles) checked before allocation. |
| `features/pdf/codec/jpeg2000/jpx_exception.dart` | `JpxException` (corrupt input) and `JpxUnsupportedException` (out-of-subset feature), both `PdfException`. |
| `features/pdf/codec/jpeg2000/pdf_jpx.dart` | The `JPXDecode` adapter: filter chaining, PDF colorspace/dimension validation, typed conflicts. |

Acceptance runs every committed fixture against its OpenJPEG oracle payload:
byte-exact for lossless, inside pre-fixed ceilings for lossy
(`tool/compare_jpx_oracle.dart` re-runs it). Arithmetic bypass, Part 2
extensions, palettes, CMYK, and packed packet headers fail typed; the browser
build must produce pixels identical to the VM (`test/web/jpx_wire_test.dart`
pins the decoded-pixel hash).

### Current PDF limits

The PDF feature aims for useful extraction, not full rendering-engine parity:

- it supports the Standard password security handler, not certificate-based public-key handlers;
- it preserves bytes only for indirect JPEG image XObjects reached by `Do`, and converts supported CCITT or JBIG2 bitmaps to grayscale PNG;
- inline images, direct image objects, and Form XObjects remain unextracted or geometry-only; JPEG 2000 follows the documented Part 1 subset;
- a Type0 composite font without `/ToUnicode` produces no recovered text even when glyph geometry is available;
- metadata strings outside UTF-16 use an approximate byte-for-byte PDFDocEncoding path, so rare high-byte characters can decode incorrectly;
- extraction stops after bounded numbers of operations, placements, objects, and images;
- the current image caps include 128 unique extracted images per book and 256 placements per page;
- an image-only scan remains without text because unseal does not run OCR;
- reflowed paragraphs and reading order are informed guesses from page geometry;
- page-faithful display must use the original bytes rather than the reflowed HTML.

## CHM: read compiled HTML Help topics

The CHM adapter reads an ITSF container, its PMGL directory, and LZX-compressed
content without a native tool. It assembles HTML topics and resources into a
`DocumentBook`, reads the `#SYSTEM` title, and follows `.hhc` contents links
for navigation. The real PuTTY manual fixture exercises compressed topics
and nested navigation. Generated CP1251, CP1252, and CP1256 fixture books
exercise names, `#SYSTEM` metadata, topics, and contents under the locale's
legacy codepage. The LZX decoder restores Intel E8 relative addresses and
keeps the stream position across frames. It does not expose the CHM full-text
index, merged help, or script execution. Frames within the current reset
interval are cached and total frame expansions are capped, so repeated entry
references cannot force unbounded decompression work.

| File | What it does and why it exists |
| --- | --- |
| `features/chm/chm_archive.dart` | Bounds and indexes the ITSF directory and reads archive entries. |
| `features/chm/chm_lzx.dart` | Expands bounded LZX blocks for compressed topics. |
| `features/chm/parse_chm_book.dart` | Builds the document, metadata, resources, and contents navigation. |

## DjVu: decode bounded JPEG, JB2, and IW44 pages

DjVu wraps page chunks in an IFF container. A single page is `FORM:DJVU`; a
bundled book is `FORM:DJVM` with a `DIRM` directory and embedded page FORMs.
Each page starts with `INFO`, which supplies dimensions, resolution, and
rotation. The adapter exposes direct `BGjp` JPEG, decodes `Sjbz` JB2 masks
with local or shared `Djbz` symbols through `INCL`, and supports progressive
IW44 v1.0 through v1.2 `BG44`/`FG44` layers. Reduced IW44 backgrounds expand
bilinearly; compound pages combine color layers through a hard `Sjbz` mask.
`FGbz` recoloring is ignored, so its foreground renders as black ink.

Compressed `TXTz` supplies searchable text and takes precedence over `TXTa`.
`NAVM` becomes navigation with verbatim bookmark targets. Indirect directories
open only through filesystem reads, which validate sibling names and component
sizes. Byte-based reads reject them. Chained shared dictionaries and replacement
visual codecs fail typed; a successful book has a displayable image for every
page. Decoded layers are capped at 2048 million pixels and 1 GiB of raster
bytes per book. IW44, BZZ, and shared JB2 symbols have separate allocation
and work limits.

| File | What it does and why it exists |
| --- | --- |
| `lib/djvu.dart` | Exposes the narrow format API. |
| `features/djvu/parse_djvu_book.dart` | Walks bounded IFF chunks, validates directory offsets and page INFO, decodes visual layers, and assembles text and navigation. |
| `features/djvu/bzz_decoder.dart` | Decodes bounded BZZ streams used by compressed text, bookmarks, and directory names. |
| `features/djvu/djvu_text.dart` | Decodes TXTz/TXTa text and its zone tree with the reference grammar's 17-byte records: 0x8000-biased coordinate and text-start deltas, 24-bit text lengths and child counts, and a plain-depth bound instead of a type ordering (real encoders nest out of order). Zones keep the stored bottom-left coordinates, their stored UTF-8 byte ranges, and their canonical UTF-16 ranges through a sparse UTF-8 offset index that refuses ranges splitting a multi-byte character. |
| `features/djvu/djvu_page_structure.dart` | The page's stable spatial structure: the native tree, the shared top-left region/line/word projection (levels a file skips stay native only), and the hidden-text canonical snapshot under the stable `djvu.hidden-text` profile. |
| `features/djvu/djvu_indirect.dart` | Validates directory records and assembles indirect components supplied by the I/O adapter. |
| `features/djvu/iw44_decoder.dart` and `features/djvu/iw44_inverse_wavelet.dart` | Decode progressive ZP-coded IW44 layers to bounded RGB rasters. |
| `features/djvu/djvu_layer_compositor.dart` | Scales validated IW44 layers and composes them through a JB2 mask into a BMP. |
| `features/djvu/jb2_decoder.dart`, `features/djvu/zp_decoder.dart`, and `features/djvu/zp_tables.dart` | Decode local and shared JB2 symbols under explicit budgets and share the DjVu ZP arithmetic coder. |
| `features/djvu/djvu_decode_budget.dart` | Reserves cumulative decoded pixel and raster-byte budgets before page allocations. |
| `features/djvu/djvu_book.dart` | Keeps page geometry, JPEG/BMP resources, OCR, and original source bytes together. |
| `features/djvu/djvu_exception.dart` | Distinguishes malformed documents from valid pages needing another image codec. |

Metadata-only reads validate the container and page INFO without decoding
image layers. Tests include a generated JPEG page, real public-domain JB2
content, Unlicense grayscale and color IW44 pages, and color/grayscale compound
pages. Chicken and boy match their upstream PNG RGB rasters exactly; the
happy-birthday composite is checked at sample points and by a full-raster
regression hash. Those binary PNG references remain outside the test corpus.
The format reference is the [DjVu 3 specification](https://www.sndjvu.org/spec.html).
The shared ZP tables and codec behavior are cross-checked with the
independent MIT-licensed [djvu-rs implementation](https://github.com/matyushkin/djvu-rs).
Fixture and reference provenance is recorded in the repository. The scanned
archive corpus additionally pins TXTz text against `djvutxt`, mask and photo
pixels against `ddjvu`, and composed-page hashes under the documented hard-mask
convention. Derived indirect fixtures verify the file-based path. See the
[parser references](format-parser-references.md) for reference conventions
and the [roadmap](roadmap.md) for remaining corpus gaps.

## ALTO: import OCR sidecars into the spatial contract

ALTO stores OCR results over scanned pages: a Description (measurement unit,
OCR software, source image), pages with declared dimensions and confidence
figures, positioned blocks, lines, and strings. The host owns the OCR
document and its link to a real page — schema validity proves nothing about
which book the OCR belongs to, so binding always takes an explicit target
snapshot.

| File | What it does and why it exists |
| --- | --- |
| `lib/alto.dart` | The public import entry point, with the shared spatial types its signatures use. |
| `features/alto/alto_document.dart` | The document model: version, unit, provenance, pages, blocks (text, composed, illustration, graphical element), lines, and strings with confidence figures. |
| `features/alto/parse_alto_document.dart` | Parses namespaces v2/v3/v4 under input and structure bounds; unknown units, namespaces without a supported version, and strings without content fail typed. Extension elements carry no positioned words and are ignored. |
| `features/alto/alto_scale.dart` | The verified conversion from document units to pixels: from a declared dpi or page-dimension agreement (1% aspect tolerance); a physical unit without evidence has no scale and refuses. |
| `features/alto/bind_alto_snapshot.dart` | The snapshot binding: a reading cursor maps each string to the first target occurrence at or after it, repeated quotes stay ambiguous with bounded candidate lists, absent words report missing, line and block spans aggregate with min/max because real blocks do not map monotonically, and a projection budget stops quadratic work. The binding preserves the target identity tuple, OCR origin, software, and confidence. |
| `features/alto/alto_exception.dart` | Malformed/out-of-subset refusals and the unverifiable-conversion error. |

## TIFF and BigTIFF: decode multi-page raster books

TIFF pages live in IFD chains: the header points at the first image file
directory, and each directory's next-IFD pointer chains to the following
page. BigTIFF widens offsets to 64 bits and entries to 20 bytes. Raster data
sits in strips or tiles described by offset/byte-count arrays. The adapter
walks the chain with cycle detection and per-entry bounds checks, expands the
supported raster codecs to BMP images, and passes through a JPEG when a page
holds exactly one self-contained strip.

Raster codecs: uncompressed, PackBits, LZW (including old-style
bit-reversed compat streams, detected through libtiff's heuristic), and
Deflate/AdobeDeflate, with horizontal-differencing predictors for 8- and
16-bit gray and 8-bit RGB; CCITT modified Huffman, Group 3, and Group 4
through a strict row-oriented decoder that mirrors libtiff's reference-run
state machine and retries EOL-less producers. Tiled raster, planar=2,
palette, float samples, LogLuv, JPEGTables-abbreviated strips, old-style
JPEG, reversed FillOrder, and uncompressed-mode extensions fail with
`TiffUnsupportedCodecException`; malformed containers, hostile offsets and
counts, IFD cycles, and truncated strips fail with `TiffException` before
any declared allocation. Documents are capped at 128 MiB of input, 1,024
pages, 65,536 IFD entries, 4 samples per pixel, a 256-megapixel page, a
million segments per page, 256 million decoded pixels per book, and 128 MiB
of decoded raster per book.

| File | What it does and why it exists |
| --- | --- |
| `lib/tiff.dart` | Exposes the narrow format API. |
| `features/tiff/tiff_container.dart` | Parses classic and BigTIFF headers, walks IFD chains with cycle detection, and reads typed values with bounds and count checks. |
| `features/tiff/tiff_page_decoder.dart` | Validates page geometry, strips and tiles, and dispatches per-codec decoding into BMP rasters or JPEG passthrough. |
| `features/tiff/tiff_ccitt_decoder.dart` | Decodes CCITT modified Huffman, Group 3, and Group 4 rows with libtiff's reference-run state machine and typed failures. |
| `features/tiff/tiff_codec.dart` | Implements PackBits and TIFF LZW (standard and bit-reversed compat), routes Deflate, applies horizontal differencing, and names codecs in typed failures. |
| `features/tiff/tiff_limits.dart` | Reserves the input, page, strip, sample, and raster budgets before allocations. |
| `features/tiff/tiff_book.dart` | Keeps page geometry, BMP/JPEG resources, and original source bytes together. |
| `features/tiff/tiff_exception.dart` | Distinguishes malformed documents from valid pages needing an unsupported codec. |
| `foundation/images/ccitt/` | The shared T.4/T.6 run-length tables and the pdf.js-derived fax decoder used by the PDF path. |
| `foundation/images/bmp_encoder.dart` | The shared 24-bit BMP writer used by the TIFF and DjVu rasters. |

Metadata-only reads validate the container and IFD chain and read the
ImageDescription, DateTime, Software, Artist, Copyright, and resolution tags
without decoding image layers. Pixels are verified against libtiff: every
tracked fixture is compared page-by-page with `tiffcmp -t` against a
`tiffcp -c none` reference, the real bilevel and gray libtiff images are
checked against their PBM/PGM pixel oracles, and raster SHA-256 goldens pin
the bytes. The corpus mixes generated fixtures (transcoded with libtiff
4.7.2's `tiffcp`) with libtiff's own MIT-licensed test images, including a
real 2453×3369 Group 4 fax page, an EOL-less Group 3 regression file, and an
old-style bit-reversed LZW book. Fixture and reference provenance is
recorded in `test/resources/tiff/PROVENANCE.md`.

## Search: query the HTML-backed content of a parsed book

Search works after parsing and reads canonical text from reading-order items marked as HTML. EPUB, PDF reflow, DOCX, and TXT can therefore share one search API. Image-only comic pages have no HTML text and produce no matches.

The flow is:

`query -> compiled query -> each reading-order section -> matches with context -> SearchResults`

| File | What it does and why it exists |
| --- | --- |
| `features/search/book_search.dart` | Traverses HTML items in reading order, applies a compiled query to canonical text, builds context snippets, and stops at the caller's result limit. |
| `features/search/query_compiler.dart` | Compiles contains, whole-word, regular-expression, and proximity queries, including Unicode boundaries and tolerant typesetting-character rules. The current proximity mode requires all query words inside the window but does not enforce their order. |
| `features/search/entities/compiled_query.dart` | Owns the compiled matcher, validates proximity candidates, and recovers the real character offsets from tolerant matches. |
| `features/search/entities/search_mode.dart` | Lists the supported search modes. |
| `features/search/entities/search_match.dart` | Describes one result through its section path, section index, character range, and surrounding snippet. |
| `features/search/entities/search_results.dart` | Groups the original query, ordered matches, and a flag that says whether `maxMatches` truncated the result. |
| `features/search/index/search_text_tokenizer.dart` | Tokenizes canonical text into normalized terms with original UTF-16 ranges. Self-contained fold tables (Latin diacritics to ASCII base, Greek/Cyrillic case, fullwidth forms); soft hyphens, zero-width characters and the listed combining marks are ignorable inside a run, so `colo­rial` indexes as `colorial` with the hyphen inside the range. |
| `features/search/index/searchable_map.dart` | Radix tree ported from MiniSearch's `SearchableMap`: exact lookup, prefix iteration over the matching subtree, and bounded fuzzy iteration sharing one incremental Levenshtein matrix. Prunes explicitly where the original relied on typed-array out-of-bounds writes. |
| `features/search/index/index_ranking.dart` | BM25+ scoring (k=1.2, b=0.7, d=0.5) and the prefix/fuzzy expansion weights, ported from MiniSearch at revision `3d239d1c`. |
| `features/search/index/book_search_index.dart` | The index itself: term postings per section with occurrence ranges, eligibility/pending/failed coverage, batched construction with cooperative cancellation, exact/prefix/fuzzy queries with the deterministic C05 tiebreak, and versioned serialization with bounded import validation. PDF indexes bind the canonical reflow profile; imported queries require live destination-text verification. |
| `features/search/index/search_index_identity.dart` | Explicit identity inputs and the C02 digest helpers (SHA-256 over UTF-16LE for text revisions and the compact reading-order JSON). Uses the shared revision digest implementation; fixed vectors live in the search test suites. |
| `features/search/index/search_index_wire.dart` | JSON-safe codecs for indexed results and coverage, shared by the isolate and worker transports. |
| `features/search/index/search_index_exceptions.dart` | The typed failure kinds: invalid argument, incompatible revision/profile, exceeded limit, cancellation, disposal, unsupported persistence. |

The index is additive to `Book.search` and addresses the same canonical space.
`BookSearchIndex.build` special-cases DjVu books: every page's hidden text
enters under the `djvu.hidden-text` profile, so indexed hits, zone lookups
and durable anchors address one text space.
Search relies on `canonical_document_text.dart`. If a parser and the Viewer count text differently, highlights and search results drift. The canonical text policy prevents that class of bug, and the index projects every token back to that space, so indexed hits cut the same characters the scan search finds.

## Locators: store a position without storing UI state

A locator describes where the reader is in a publication. It does not store pixels, scroll-controller offsets, or widget state because those values change across devices and layouts.

| File | What it does and why it exists |
| --- | --- |
| `features/locators/book_locator.dart` | Defines text, CFI, and page locators plus quoted surrounding text. Each subtype records the information suitable for its content model. |
| `features/locators/locator_codec.dart` | Encodes locators to maps and decodes persisted maps with validation. Storage knowledge stays out of the locator entities. |
| `features/locators/search_locator.dart` | Converts search matches into portable text locators. |
| `features/locators/fuzzy_relocation.dart` | Repairs a text locator after content changes by finding exact occurrences of its selected quote. Prefix and suffix context score duplicate occurrences; they are not searched independently. |

Fuzzy relocation exists because a saved character offset becomes stale when a book is replaced or normalized differently. The quoted context gives the library evidence for finding the same passage again.

## Annotations: persist bookmarks and highlights

Annotations are portable records. The Viewer can render them, but unseal owns their data shape, serialization, and merge policy so storage does not depend on Flutter widgets.

| File | What it does and why it exists |
| --- | --- |
| `features/annotations/bookmark_record.dart` | Defines a bookmark identifier, title, section and character offset, creation time, and optional note. |
| `features/annotations/entities/highlight_record.dart` | Defines highlight ranges, note text, decoration style, palette or custom color, and its creation timestamp. |
| `features/annotations/annotation_codec.dart` | Encodes and decodes annotation collections with a versioned JSON shape and validated record fields and color values. An optional CFI remains a string here rather than a decoded `BookLocator`. |
| `features/annotations/highlight_merge.dart` | Owns the public highlight merge operation and its highlight-specific identity and ordering rules. |
| `features/annotations/bookmark_merge.dart` | Owns the public bookmark merge operation and its bookmark-specific identity and ordering rules. |
| `features/annotations/annotation_merge_engine.dart` | Implements the private deterministic reconciliation algorithm shared by the two public merge operations. |

The merge code exists for offline-first clients. It produces a deterministic result for one call whose local and incoming sides are defined. Equal timestamps deliberately keep the local record, so two devices that each call their own copy "local" are not automatically guaranteed to converge without a higher-level synchronization policy.

### Durable anchors: selections that survive edition changes

`features/annotations/durable/` adds a durable annotation envelope beside the
v1 records. Each envelope uses its own codec. The split:

| File | What it does and why it exists |
| --- | --- |
| `features/annotations/durable/anchor_limits.dart` | Declares the finite work and size bounds (quote, context, candidates, scan budget, fuzzy budget, payload, selector lengths); public entry points validate before relying on them. |
| `features/annotations/durable/annotation_anchor.dart` | The `AnnotationAnchor` envelope: publication identity, section occurrence, extraction profile, text revision, UTF-16 bounds and the bounded quote/context evidence — never the section text. `capture` cuts the evidence from a `CanonicalTextSnapshot`. |
| `features/annotations/durable/anchor_codec.dart` | The versioned anchor wire: structured-clone-safe maps, digest and profile revalidation, limit enforcement, typed hostile-input failures, and explicit refusal to export in-memory-only identities. |
| `features/annotations/durable/anchor_resolution.dart` | The outcome union (`resolved`/`ambiguous`/`missing`/`incompatibleRevision`/`unsupported`), the `AnchorPolicy` values, and what each outcome carries. |
| `features/annotations/durable/durable_annotations.dart` | The facade (`capture`, `resolve`, book-level snapshot helpers) and the evidence ladder: identity reuse first, then exact scan, whitespace-normalized scan, and the gram-seeded bounded fuzzy pass. Ties stay ambiguous; budgets report `unsupported`. |
| `features/annotations/durable/w3c_annotation_adapter.dart` | The declared W3C subset (TextQuote/TextPosition selectors), code point ↔ UTF-16 conversions with mid-surrogate refusals, loss-reported truncation, and explicit unknown-selector reporting. |

Resolution is a pure function over target snapshots, so the same code answers
EPUB section moves and PDF mode switches — PDF pages enter through their
`PdfPageStructure` canonical snapshots (one profile per reading mode). The
fuzzy pass ports Hypothesis's anchoring approach with declared bounds; see
`THIRD_PARTY_NOTICES.md` for what is deliberately stricter than the oracle.

## CFI: address a position inside EPUB structure

EPUB CFI is a compact path language. It can point through the EPUB package document and into an HTML content document, then optionally to a character offset. Assertions help verify that the path still names the expected node.

| File | What it does and why it exists |
| --- | --- |
| `features/cfi/epub_cfi.dart` | Defines the CFI syntax model and parser, including paths, segments, steps, assertions, offsets, ranges, escaping, and serialization. |
| `features/cfi/epub_cfi_document.dart` | Builds a lightweight document tree from HTML or XML and provides node and text-boundary operations used during CFI traversal. |
| `features/cfi/epub_cfi_resolver.dart` | Resolves a CFI against an `EpubBook` and builds a CFI from a content index and text offset. It bridges EPUB addressing and common reading positions. |

CFI and `BookLocator` are related but not identical. CFI is an EPUB standard. Locators are unseal's cross-format position model.

## Reading progression and navigation targets

`book_progression.dart` and `nav_resolution.dart` are listed with Reading above, but they also connect search, locators, and viewers:

- progression expresses a known section and character position as a fraction of the whole book;
- navigation resolution turns a format-produced table-of-contents link into a content index, fragment, MOBI file position, or unresolved target;
- locators persist a position with enough evidence to restore it later.

Keeping these concepts separate prevents one overloaded "position" type from mixing percentages, document paths, DOM fragments, PDF pages, and character offsets.

## OPDS: parse a catalog, not a book file

OPDS is a publication-discovery format built on Atom XML. A feed contains catalog entries and links. Acquisition links point to downloadable publications. Navigation links point to other catalog feeds. Cover links point to images.

| File | What it does and why it exists |
| --- | --- |
| `features/opds/opds_feed.dart` | Parses OPDS 1.x Atom XML into `OpdsFeed`, `OpdsEntry`, `OpdsAuthor`, and `OpdsLink`, then exposes acquisition, navigation, search, next-page, cover, and thumbnail relationships. |

This feature does not make network requests and does not parse the downloaded EPUB or PDF. A client fetches the feed, chooses an acquisition link, downloads its bytes, and passes those bytes to `Unseal`.

The convenience getter for acquisition links currently recognizes only the exact base relation `http://opds-spec.org/acquisition`. Specialized acquisition relations for cases such as borrowing, buying, or open access are not included by that getter.

## Calibre: read an existing library database

Calibre stores library metadata in SQLite. The database refers to books and their available format files. unseal reads the SQLite file format directly and converts the required tables into small domain values. It does not manage the Calibre application, execute SQL, mutate the database, or open the listed ebooks.

| File | What it does and why it exists |
| --- | --- |
| `features/calibre/calibre_database.dart` | Defines `CalibreBook` and provides the public read API. It reads `sqlite_master` to discover table layouts, joins the Calibre book, author, tag, series, identifier, and format rows, and builds the resulting domain values. |
| `features/calibre/sqlite_database.dart` | Implements the dependency-free subset of SQLite needed here: file headers, table B-trees, rowids, variable-length integers, record values, and overflow-page chains. |

The SQLite reader is intentionally limited to whole-table scans of the rowid tables needed by `metadata.db`. It is not a general SQL engine.

## Platform: keep the same API on native Dart and the web

Book parsing can take enough CPU time to freeze an application's interface. Native Dart can move work to an isolate. Browsers use Web Workers. unseal hides that difference behind `Unseal` and conditional imports.

The normal asynchronous path for synchronously parsed formats is:

```text
Unseal.read
    -> BookDispatch.openFromBytes
    -> validate and detect the input
    -> native: Isolate.run
       web with configured worker: postMessage
       web without worker: inline fallback
    -> BookDispatch.parseBook
```

CB7 and CBC are exceptions. `BookDispatch.openFromBytes` detects them and calls their asynchronous archive parsers directly before the isolate or Web Worker executor. The synchronous parse inside the normal executor detects the format again before dispatching it.

### Shared facade and native implementation

| File | What it does and why it exists |
| --- | --- |
| `platform/unseal_reader.dart` | Exposes the main `Unseal` API for reading, inspecting a full open, or reading metadata. It delegates parsing to `BookDispatch` and combines embedded metadata, OPF sidecars, and filename fallback on path-based reads. |
| `platform/unseal_worker.dart` | Configures the optional web worker and exposes search and CFI operations against the last book kept inside that worker through `UnsealWorker`. |
| `platform/io/background_parse.dart` | Runs parsing and metadata work in `Isolate.run` on native Dart, with a controlled fallback when isolate execution is unavailable. |
| `platform/io/book_path_reader.dart` | Reads local paths and looks for neighboring OPF sidecars such as `<book>.opf` or `metadata.opf`. |
| `platform/io/worker_client.dart` | Supplies the native no-op implementation of web-worker configuration. Resident worker operations return `null` so callers can use their inline path. |

`Unseal.parse` is synchronous. A UI should normally use `Unseal.read` or `Unseal.readFile` so the platform layer can move expensive work away from the UI thread.

### Web implementation and worker protocol

| File | What it does and why it exists |
| --- | --- |
| `platform/web/background_parse.dart` | Sends parsing to the configured worker and falls back to inline execution if no healthy worker is available. |
| `platform/web/book_path_reader.dart` | Rejects filesystem paths on the web because a browser cannot open arbitrary local paths through Dart I/O. |
| `platform/web/book_wire.dart` | Defines operation names, message keys, reply shapes, and shared exports for the internal worker protocol. |
| `platform/web/worker_client.dart` | Owns the browser worker lifecycle, request identifiers, pending futures, replies, failures, fallback state, and resident-book requests. |
| `platform/web/worker_ops.dart` | Runs parse, metadata, search, and CFI operations without importing browser APIs. The compiled worker entry point delegates messages here. |
| `platform/web/wire/book_wire_codec.dart` | Encodes and reconstructs each concrete `Book` subtype that can cross the worker boundary. |
| `platform/web/wire/book_components_wire.dart` | Encodes navigation, files, and archive entries while moving large strings and bytes into a separate blob list. |
| `platform/web/wire/metadata_wire.dart` | Encodes `BookMetadata` and transfers cover bytes through the blob list. |
| `platform/web/wire/epub_package_wire.dart` | Encodes and reconstructs EPUB 2 and EPUB 3 package entities used by `EpubBook`. |
| `platform/web/wire/mobi_wire.dart` | Selects the MOBI or KF8 record zero data needed to rebuild MOBI-specific state on the receiving side. |
| `platform/web/wire/search_wire.dart` | Encodes and decodes `SearchResults` and individual matches. |
| `platform/web/wire/cfi_wire.dart` | Encodes and decodes resolved EPUB CFI locations. |
| `platform/web/wire/spatial_wire.dart` | Encodes one DjVu page structure (flat depth-first zone records plus the page text blob) and one bound ALTO spatial text as structured-clone-safe maps; rebuilds both on the receiving side. |
| `platform/web/wire/error_wire.dart` | Translates known package exceptions across the worker boundary so the caller receives useful error types and messages. |
| `platform/web/wire/json_wire.dart` | Converts the protocol's small map structures to and from JSON. Large payloads stay outside JSON. |
| `web/unseal_worker.dart` | Compiles as the JavaScript worker entry point, accepts browser messages, keeps the last parsed book resident, calls `runWorkerOp`, and posts structured replies. |

The wire protocol is internal transport, not a saved-file format. Structure travels in small maps. HTML strings, image bytes, fonts, and other large values travel in a blob list that the browser can copy with structured clone.

## Progressive reading: keep content in a session

`BookSession`, exported by `package:unseal/unseal.dart`, opens EPUB, CBZ,
CBR, PDF, and MOBI/AZW3. Its `book` is a concrete format-specific header
with no content in `files`; callers request resources, document source, or
canonical text. PDF adds requested page geometry and original byte ranges;
MOBI sessions serve sections and parts by name and images, fonts, CSS and
SVG flows as resources. DRM-protected MOBI fails typed; AZW4 and non-MOBI
Palm databases throw `SessionUnsupportedFormatException`.

| File | What it does and why it exists |
| --- | --- |
| `features/progressive/book_session.dart` | Defines opening, resource/text requests, search, statistics, progression, CFI, cancellation, and disposal. |
| `features/progressive/session_policy.dart` | Defines cache, cover, and byte-range limits plus session lifecycle errors. |
| `features/progressive/mobi_session_header.dart` | Builds MOBI/AZW3 session headers and their serving state: the open pass over records, MOBI 6 section materialization (anchor-chain splices, body-range clamping, wrapper stripping), KF8 per-part assembly with bounded position resolution, and the lazy resource walk. |
| `features/progressive/session_metrics.dart` | The shared session counter (source reads, decoded units and bytes, materialized content), the counting byte source, and the `SessionMetrics` snapshot behind `BookSession.metrics`. |
| `features/progressive/session_engine.dart` | Owns the resident source, format-specific opening, header, cache, and requested operations. |
| `features/progressive/transport/session_transport.dart` | Defines the transport contract and inline execution. |
| `features/progressive/transport/session_transport_io.dart` | Keeps a session in a long-lived VM isolate and reads file sources there. |
| `features/progressive/transport/session_transport_web.dart` | Routes requests to the configured browser worker, with inline execution when unavailable. |

Browser session identifiers keep separate engines for concurrent books.
`cancelPending` fails in-flight requests but leaves the session usable;
`dispose` ends it and rejects later requests. Whole-book operations may
traverse all content. Compressed CBR entries inflate at opening, and comic
search has no matches because image pages have no text. Sessions do not own
OCR or a reader UI.

## How the features depend on each other

The arrows below mean "imports or depends on":

```text
platform -> reading dispatch -> format parsers -> foundation
detection -> foundation
search -> foundation
reading progression and navigation resolution -> foundation
locators -> foundation
annotations -> locators and foundation
EPUB CFI -> EPUB and foundation
OPDS -> foundation metadata values
Calibre -> foundation metadata helpers
```

Foundation never imports a format parser. Search does not import EPUB or PDF. Generic locators do not import CFI internals. OPDS does not download a publication. Calibre does not parse the ebook files listed in its database.

The intentional cross-feature cases are narrow:

- `BookDispatch` imports all parser entry points because parser selection is its job.
- AZW4 calls the public PDF parser because an AZW4 publication contains a PDF payload.
- PalmDOC reuses the MOBI feature's bounded Palm Database record reader and the TXT converter.
- CBC calls comic parsers because a collection contains nested comic archives.
- EPUB CFI accepts `EpubBook` because CFI is defined specifically for EPUB structure.

## Read a feature without getting lost

Use the same order for every format:

1. Read its `lib/<format>.dart` entry point to see the public contract.
2. Read `parse_<format>_book.dart` to understand the complete story.
3. Read the concrete book entity to see which information survives parsing.
4. Read container and header files to understand the source structure.
5. Read metadata, navigation, resources, and rendering files as separate policies.
6. Read codec or compression algorithms last. At that point you know who calls them and what result they must produce.
7. Read the matching tests to see supported inputs, intentional degradation, and explicit rejection.

For a format-neutral feature such as search or annotations, start with its public operation, then its result types, and then its codec or merge policy.

## Questions that reveal whether a file is necessary

Do not start by asking whether a file is long. Ask what decision it owns.

- Which input does this file understand that its caller should not need to understand?
- Which invariant does it keep true?
- Which source-format detail does it translate into the common model?
- Does another feature use the same policy, or only similar-looking syntax?
- Would deleting the file move its decisions into an unrelated orchestrator?
- Could a new implementation replace it through a real interface or data boundary?
- Does the failure happen at the layer that can explain it clearly?

A large decoder can be cohesive. A five-line wrapper can be unnecessary. File size is evidence about reading cost, not a design verdict.

## Details that often surprise new contributors

- A ZIP signature does not identify EPUB. The dispatcher opens the archive and inspects its contents.
- `BookFormat` names the final format. `DetectedFormat` can name only a broad family.
- `TextFile.plainText` removes markup and collapses whitespace for reading and statistics. `documentTextOf` preserves the visible character space used by positions. Do not interchange them.
- EPUB manifest order, spine order, and table-of-contents order are different concepts.
- PDF text is reconstructed from drawing commands and font mappings. It is not stored as paragraphs.
- Comic files have reading order but usually have no searchable HTML text.
- CB7 and CBC require the asynchronous opening path.
- An OPDS feed describes publications and download links. It is not itself a publication.
- Calibre exposes catalog records. Opening the referenced book is a separate operation.
- The web worker keeps only the last successfully parsed book for resident search and CFI operations.
- Path-based metadata reading can merge a neighboring OPF sidecar and infer missing values from a filename. Byte-only reading cannot discover those external files.
- "Fuzzy relocation" requires an exact selected-text match. Context helps choose between duplicate matches.

## Keep this guide useful

When a change adds, removes, or renames a Dart file under `lib/`, update the matching table in this guide in the same commit. Describe the file's owned decision, not its classes line by line.

When a change alters a format flow, update its flow before adding implementation detail. When a change introduces a new term from a file format, define that term near its first use.

Contributors should use this guide as an index, then verify the relevant code before changing behavior. The code and tests remain authoritative when this document and the implementation disagree.
