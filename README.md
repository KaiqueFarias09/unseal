<p align="center">
  <img src="https://raw.githubusercontent.com/KaiqueFarias09/unseal/main/logo.webp" alt="Unseal logo" width="180">
</p>

<h1 align="center">Unseal</h1>

<p align="center">
  <a href="https://pub.dev/packages/unseal"><img src="https://img.shields.io/pub/v/unseal.svg?logo=dart&amp;label=pub.dev" alt="pub.dev package"></a>
  <a href="https://github.com/KaiqueFarias09/unseal/actions/workflows/dart.yml"><img src="https://github.com/KaiqueFarias09/unseal/actions/workflows/dart.yml/badge.svg" alt="Dart CI"></a>
  <a href="https://github.com/KaiqueFarias09/unseal/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-%3E%3D3.8.0-0175C2?logo=dart" alt="Dart SDK 3.8 or newer"></a>
</p>

Unseal is a pure-Dart book parser and reading-data library. Give it bytes or a
filesystem path and receive one format-neutral `Book` model with metadata,
cover data, files, reading order, navigation, and statistics.

It supports EPUB, MOBI, AZW3, PalmDOC, eReader and Plucker PDB, RTF, Markdown,
Sony LRF and LRX metadata, FB2, TXT, HTML, CHM, DOCX, ODT, AZW4, comic
archives, PDF, DjVu, and TIFF/BigTIFF without a native executable, FFI bridge,
or Flutter dependency in the library itself.

Unseal is a parser and data layer, not a reader UI or a general-purpose
document renderer.

## At a glance

- One API for metadata-only scans and full book parsing.
- Common models for metadata, HTML content, stylesheets, images, fonts,
  navigation, covers, and reading order.
- Format detection, full-text search plus an optional ranked inverted index,
  reading progression, portable locators, Readium Locator interchange and
  position lists, EPUB CFI operations, annotation
  codecs, and OPDS feed parsing.
- Pure Dart on the Dart VM, Flutter native targets, and browser JavaScript.
- Optional web-worker parsing for browser applications.
- Typed exceptions and format-specific recovery paths for damaged input.

Start with [installation](#installation) and the [quick start](#quick-start).
The [documentation index](doc/README.md) links to usage, architecture,
development, and the single [roadmap](doc/roadmap.md).

## Supported formats

| Format | Main capabilities | Important boundary |
| --- | --- | --- |
| EPUB 2/3 | OPF metadata, spine (including `linear="no"` items), XHTML, SVG content documents, CSS, images, fonts, media overlays, navigation, and CFI; EPUB 3 page list, landmarks, rendition, accessibility metadata, and fixed-layout viewports with effective per-page rendition helpers | Font obfuscation is limited to the standard IDPF and Adobe algorithms. |
| KEPUB | Kobo EPUB packages are read through the EPUB parser, preserving Kobo spans and EPUB content. | Reported as `BookFormat.epub`; a Kobo-specific format type is not inferred from ZIP bytes. |
| MOBI 6 | PalmDOC and HUFF/CDIC decompression, EXTH metadata, chapters, images, fonts, and navigation | DRM-protected books are rejected. |
| PalmDOC PDB | Uncompressed or PalmDOC-compressed `TEXt/REAd` records, title, and plain reading text | Other PDB ebook families use separate parsers. |
| eReader PDB | Unencrypted `PNRd/PPrs` records with PML emphasis, headings, local links, PNG images, footnotes, sidebars, and title/author metadata | Reading-oriented HTML does not reproduce page layout or every PML control; protected books are rejected. |
| Plucker PDB | `Data/Plkr` text pages, continued records, paragraph links and inline formatting; Palm 1/2/4-bit grayscale, 8-bit system and custom palettes, and 16-bit RGB565 direct-color images | Palette and RGB565 paths are covered by generated Palm-bitmap fixtures; no real Plucker book using those variants has been verified. Internally compressed bitmaps, bookmarks, and owner-keyed documents are not converted. |
| Sony LRF | BBeB metadata, ordered text pages, table of contents, and embedded JPEG/PNG/BMP/GIF images for versions 1–800 and 801+ | Reflowed content rather than Sony's fixed layout. Exact typography, ruby styling, and complex canvas layouts are outside this contract. |
| Sony LRX | Plaintext metadata from the LRX2 BBeB wrapper | Protected book content is rejected with `DrmProtectedException`; metadata-only support does not decrypt or render it. |
| AZW3 / KF8 | Skeleton and `div` reassembly, FDST flows, CSS/SVG, images, NCX navigation, and joint MOBI/KF8 files | DRM-protected books are rejected. |
| FB2 / FBZ | Metadata, covers, declared encodings, notes, links, styles, and section navigation | The result is a reflowable HTML representation. |
| TXT / TXTZ | UTF-8/UTF-16 decoding, paragraph-preserving XHTML, archive resources, and basic Markdown/Textile | Not a full Markdown or Textile implementation. Plain TXT metadata is limited. |
| Standalone Markdown | CommonMark blocks and inline formatting, headings, links, and simple front matter | Byte-only calls use `parseMarkdownBook`; `readFile` recognizes `.md`, `.markdown`, and `.mdown`. Relative resources are references, not extracted files. |
| RTF | Text, title/author, paragraphs, Unicode, codepages 1251/1252/1256 and UTF-8, and basic emphasis | Tables, pictures, drawing objects, fields, and page layout are not converted. |
| HTML / HTMLZ | Source-preserving HTML, head metadata, heading navigation, OPF manifests, and resources | HTML is preserved, not sanitized. |
| CHM | ITSF directory, LZX-compressed HTML topics and resources, `#SYSTEM` title/home, nested `.hhc` contents, Intel E8 restoration, and Windows-1251/1252/1256 text from the locale record | Other legacy codepages, full-text index, merged help collections, and embedded scripts are outside this contract. |
| DOCX | Open XML document structure, styles, headings, lists, tables, links, properties, and images | Semantic conversion; not pixel-perfect Word layout. |
| ODT | OpenDocument paragraphs, headings, styles, lists, tables, images, links, and metadata | Semantic conversion; not pixel-perfect LibreOffice layout. |
| AZW4 | PalmDB/MOBI wrapper validation, PDF extraction, metadata, pages, and original PDF bytes | Requires a valid, unencrypted PDF payload. |
| CBZ | ZIP comic pages, `ComicInfo.xml` reading direction and page roles, natural ordering, and declared front cover | Page-oriented data; no comic UI is included. |
| CBR | RAR 4 stored and ordinary non-solid method-29 entries; RAR 5 stored entries and compressed streams (algorithm version 0, methods 1-5, delta/E8/E8-E9/ARM filters, dictionaries up to 64 MiB), solid chains included; declared BLAKE2sp digests (hash type 0) verify with the CRC-32 | Split (multi-volume), encrypted, linked entries, PPMd, RAR VM, later algorithm versions, other hash-record types and shapes, and oversized dictionaries are rejected typed. Solid chains decode sequentially in container order; the per-entry solid bit continues the shared dictionary and the archive-level flag alone leaves entries independent. Compressed RAR 4 PPMd/VM streams remain on the roadmap. |
| CB7 | 7-Zip comic pages, `ComicInfo.xml` reading direction and page roles, natural ordering, and declared front cover | Asynchronous only; encrypted or unsupported entries are rejected. |
| CBC | Top-level `comics.txt` collections containing CBZ, CBR, or CB7 files | The collection is flattened into one `ComicBook` page sequence. |
| PDF | Metadata, bookmarks, page text with extraction diagnosis, conservative two-column reflow, facsimile data, JPEG/JPEG 2000/CCITT/JBIG2 images, and structured layout: words, blocks, columns, tables, and stable source anchors mapped to canonical text | Reading-oriented extraction, not OCR or a general-purpose PDF renderer. JPEG 2000 supports the documented Part 1 subset below. |
| DjVu (JPEG, JB2, and IW44 subset) | Direct `BGjp` JPEG pages, `Sjbz` masks with shared `Djbz` dictionaries and `INCL` references, progressive `BG44`/`FG44` layers, and INFO dimensions and rotation in single-page or bundled documents; compressed `TXTz` hidden text, legacy `TXTa` OCR, and `NAVM` bookmark outlines | JB2 masks and composed IW44 pages become BMP images. Compressed text is byte-exact against `djvutxt`. Indirect document directories resolve through file-based opens only; `FGbz` recoloring, `FGjp`/`Smmr` layer replacements, `ANTz` annotations, and thumbnails are ignored or rejected as described below. |
| TIFF / BigTIFF | Baseline uncompressed, PackBits, LZW, and Deflate/AdobeDeflate raster pages (8-bit gray and RGB, 16-bit gray, bilevel, with horizontal-differencing predictors), planar RGB (`PlanarConfiguration` 2, unsigned 8/16-bit, three planes, by strips or tiles, predictor stride one per plane), palette pages (`PhotometricInterpretation` 3, 1/2/4/8-bit indices through an exact-size 16-bit ColorMap, projected with libtiff's rule), CCITT Group 4 and Group 3 (including modified Huffman and EOL-less producers), in strips or in tiles (tile grids with edge padding, tile addresses under the tile or the strip tags, Orientation 1-4 brought to top-left), multi-page IFD chains mixing strips, tiles, planar, and palette pages in both byte orders, BigTIFF 64-bit offsets, ImageDescription/DateTime/Software/Artist metadata, and X/Y-resolution DPI | Pages become BMP images (JPEG passthrough when a page holds one self-contained strip). Planar alpha/extra samples, planar CCITT/JPEG, 16-bit palettes, palette + Predictor 2, palette + CCITT, float/SampleFormat 2/3/5/6, LogLuv, JPEG tiles and JPEGTables-abbreviated strips, old-style JPEG, reversed FillOrder, transposed Orientation 5-8, and uncompressed-mode extensions are rejected typed. A page or a tile footprint is capped at 256 megapixels; band, tile, and strip addresses are bounds- and overlap-checked (across bands too) before allocation; a document is capped at 128 MiB input, 1024 pages, 256 megapixels of decoded pixels, 128 MiB of resident decoded bytes (page images, all live band buffers, palette tables, and scratch), and 512 MiB of decode work. Pixels, band samples, palette indices, and ColorMaps are compared with libtiff 4.7.2 at zero tolerance ([doc/tiff-tiles.md](doc/tiff-tiles.md), [doc/tiff-planar-palette.md](doc/tiff-planar-palette.md)). |

`OPF` is not a standalone reading format. When unseal finds `metadata.opf`
inside TXTZ or HTMLZ, or a sibling `<book-name>.opf` beside a native file, it
uses it as a metadata and manifest sidecar.

## Installation

```sh
dart pub add unseal
```

Or add the dependency manually:

```yaml
dependencies:
  unseal: ^1.3.0
```

The package requires Dart `>=3.8.0 <4.0.0`.

## Quick start

The byte-based asynchronous API is the most portable entry point:

```dart
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

Future<Book> openBook(Uint8List bytes) {
  return Unseal.read(bytes);
}

Future<void> inspectBook(Uint8List bytes) async {
  final book = await openBook(bytes);

  print(book.format.name);
  print(book.metadata.title);
  print(book.metadata.authors);
  print(book.metadata.cover?.bytes);
  print(book.navigation.navPoints);
  print(book.files.html.length);
  print(book.statistics.wordCount);
}
```

For a library scanner that does not need the content files:

```dart
final metadata = await Unseal.readMetadata(bytes);
print(metadata.title);
print(metadata.authors);
```

To report whether the full book can be opened, use `inspect`. It performs the
same parse as `read` and keeps the opened book in the result, so the application
does not need to parse it again:

```dart
final inspection = await Unseal.inspect(bytes);
if (inspection.canOpen) {
  final book = inspection.book!;
  print(book.metadata.title);
} else {
  print(inspection.error); // Typed UnsealException.
}
```

`detectedFormat` is only a signature-level family hint; `format` identifies the
concrete format after a successful open. Inspecting is not a lightweight
metadata scan; use `readMetadata` for that.

On native platforms, filesystem paths are also supported:

```dart
final book = await Unseal.readFile('/books/wonderland.epub');
final metadata = await Unseal.readMetadataFile('/books/wonderland.epub');
```

A standalone Markdown file is selected by its path extension. With bytes
alone, use the format-specific entry point because Markdown has no reliable
signature:

```dart
import 'package:unseal/markdown.dart';

final book = parseMarkdownBook(markdownBytes, sourceName: 'notes.md');
```

Initial Markdown front matter accepts single-line `key: value` entries and
dash lists for `authors`, `languages`, and `tags`. Supported metadata
includes `title`, `author(s)`, `language(s)`, `tag(s)`, and
`description`. It is a deliberately small subset, not arbitrary YAML.

Path-based reads are filesystem-only and read the input file into memory before
parsing. They also look for a sibling `<book-name>.opf`, followed by
`metadata.opf`, and merge available sidecar metadata.

### Progressive sessions for large books

`Unseal.read` materializes the whole book before returning. A `BookSession`
returns its structure first and loads requested content through a resident
isolate on the VM or a configured Web Worker in the browser. Inflated
resources use a byte-budgeted LRU cache:

```dart
final session = await BookSession.openFile(path);
final book = session.book; // structure only: metadata, navigation, reading order

final first = book.readingOrder.first;
final chapter = await session.loadDocumentSource(first.name); // raw HTML
final text = await session.loadDocumentText(first.name); // canonical text space
final results = await session.search('island');
final progress = await session.computeProgression();
final cfi = await session.buildCfi(contentIndex: 0, offsetInText: 120);

session.cancelPending(); // fail in-flight requests with SessionCancelledException
session.dispose(); // end the session; later requests fail with SessionClosedException
```

`session.book` is a real `EpubBook`, `ComicBook`, `PdfBook` or `MobiBook`
whose structure is complete (spine, rendition data, navigation, container
inventory, the cover when it fits `SessionPolicy.coverMaxBytes`, page
geometry for PDFs, MOBI navigation with section-qualified targets) while
`files` carries no content — spine-driven consumers such as fixed-layout
readers work unchanged, and `loadResource(path)` serves any container entry
on demand. EPUB, CBZ, CBR, PDF, MOBI 6 and AZW3/KF8 open progressively
today; DRM-protected MOBI fails with the typed DRM error, and other formats
throw `SessionUnsupportedFormatException` and should use `Unseal.read`
instead. AZW4 books (PDF wrappers) also stay on the eager path. PDF sessions materialize pages on demand
(`loadDocumentSource('page_<i>.html')`, `loadPdfPageLines(i)` for the
facsimile text-layer geometry) and serve byte ranges of the original
document via `loadBytesRange`. Compressed CBR entries inflate while the
session header sniffs page types at opening (one decode per page), and
session startup overhead can outweigh savings for small books.
The classic entry points retain their full-book behavior.

`SessionPolicy` defaults to a 64 MiB resource cache, an 8 MiB header cover
limit, and an 8 MiB cap per byte-range response. Whole-book operations such
as search and statistics can still traverse all content. CBZ/CBR search
returns no matches because their pages have no searchable text; sessions do
not perform OCR. In browsers, use `BookSession.open(bytes)` and configure
the worker as shown below. Without a healthy worker, sessions execute inline.

### Sessions over your own byte ranges

When the book lives behind your own transport — an HTTP server that
answers Range requests, object storage, a sync cache — open the session
over a source you own instead of handing over bytes:

```dart
final session = await BookSession.openSource(myHttpByteSource);
```

Implement `UnsealByteSource`: report `length` and, when you can verify
identity, a `revision` token (an ETag works); answer `readRange(offset,
count)` with exactly `count` bytes; release the transport in `close`.
Unseal orders the reads — for EPUB and CBZ, one end-of-central-directory
tail scan, the central directory, then one local header plus one
compressed payload per entry; a Deflate entry's real decompression unit
is its whole compressed payload, which is exactly what gets requested.
Opening an 11 MB EPUB transfers a few percent of it. PDF parses
demand-driven: the `startxref` tail, the xref chain windows, the object
windows the structure walk touches, and each materialized page's
streams arrive as separate exact ranges, so open plus first content
stays a small fraction of a normally shaped document (measured on the
committed fixtures: ~13% of a 2.3 MB scanned file, ~35% of a 1.9 MB
designed one, ceiling 50%). HTTP, authentication, storage, and retries
stay with you. Sessions opened this way cover EPUB, CBZ and PDF;
other formats are refused with `SessionUnsupportedFormatException`
and keep their bytes/file opens. Encrypted PDFs take the standard
password through `BookSession.openSource(source, password: ...)`.

Budgets live in `SessionPolicy`: `rangeRequestsInFlight` and
`rangeBytesInFlight` cap concurrent reads (extra requests queue —
backpressure, not failure), and `rangeRequestBytes` refuses any single
request above the cap instead of silently downloading the container.
The revision token you reported at open stamps every read; a source
whose revision changes under an open session fails its reads with
`ByteSourceRevisionChangedException` instead of mixing file states.
The source is closed when the session is disposed.

`cancelPending` fails queued and active requests and ignores their late
answers. A host read already in progress still occupies its in-flight slot
and bytes until it settles: `UnsealByteSource` has no abort operation. New
requests can use remaining capacity; with a one-request cap, an unresponsive
host read must settle before another physical read starts.

PDF sessions over byte sources expose their read ledger through
`session.metrics()`: `pdfRangeFetches`, `pdfRangeFetchBytes` and
`pdfRangeUniqueBytes` report completed range reads.
`pdfRangeResidentPeak` shows retained range payloads. Between parser steps,
the eviction target is at most half the source (with a 1 MiB floor); pinned
ranges within a step cannot exceed `cacheBytes`. Temporary read copies are
separately limited to the minimum of `rangeRequestBytes`,
`rangeBytesInFlight`, and `cacheBytes`. The coverage ledger stores offsets,
without retaining fetched payloads. `pdfRangeQueuedStepsPeak` reports the
parser queue absorbing concurrent page loads. Recovery scans on damaged documents keep their
eager-parse semantics — each scanned window is a real, counted range.

PDF sessions derive their reflow plan from up to 20 sampled pages. For longer
documents, that plan differs from a full parse, so the two modes carry
different canonical text profiles (`document` versus `session-sample`) and a
snapshot captured in one mode refuses to reuse in the other. Positions stay
stable across the switch through source anchors: capture a `PdfSourceRange`
on `loadPdfPageStructure`'s structure (page, line index, UTF-16 bounds) and
`mapSourceRange` resolves it into any canonical text as
`mapped`/`ambiguous`/`missing`/`unsupported` — the anchor never depends on
the reflow plan.

### Indexed search

For repeated queries, prefix completion and typo tolerance, build an
inverted index over a book: ranked BM25+ results, bounded fuzzy matching,
and hits that cut the same canonical text `Book.search` addresses. `Book.search`
is unchanged; the index is additive:

```dart
final index = await BookSearchIndex.build(book); // batches, yields between them
final results = index.query('navegacao', mode: IndexedQueryMode.prefix);
final locator = results.hits.first.toTextLocator(); // same offset space as Book.search
```

Normalization folds case and Latin diacritics (an unaccented query finds
`navegação`), joins soft-hyphen and zero-width splits inside word runs, and
folds Greek and Cyrillic case; scripts without tables (CJK, Hangul, Arabic,
astral planes) index verbatim. Hits carry a snippet, the section's score, and
the deterministic order score-desc, then section, start, end. Multi-token
queries require every token and anchor hits on the first token's occurrences.
Prefix and fuzzy expansion is capped (`SearchIndexLimits.maxExpansions`), so an
adversarial token fails with `SearchIndexLimitExceededException` instead of
hanging.

Construction is incremental and observable. `coverage` reports eligible,
indexed, pending and failed sections; `isComplete` means every eligible
section is indexed. Queries over a partial index answer from what is indexed
and carry the coverage, so an empty result never proves absence in the book:

```dart
final coverage = await session.buildSearchIndex(sectionsPerBatch: 4);
final found = await session.searchIndexed('nave', mode: IndexedQueryMode.prefix);
await session.exportSearchIndex(); // versioned payload; import re-verifies digests
```

Serialized payloads are versioned JSON-safe maps an application may persist.
Import validates schema, tokenizer and extraction profiles, identity,
reading-order revision, and structural bounds. Pass a destination `book` or
`sectionText` resolver to `BookSearchIndex.deserialize` to verify the live
text before querying. Structural imports allow metadata inspection but refuse
queries without a live destination. Session imports verify their own materialized text.
Changed text, order, or profile throws `SearchIndexIncompatibleException`.
PDF indexes reopen within the same extraction mode; eager and progressive
modes use different reflow profiles and require rebuilding when switching.
The index retains its sections' text for snippets until `dispose`.

### Format-specific APIs

The package exports dedicated entry points when an application needs details
from one format:

```dart
final epub = parseEpubBook(bytes);
final mobi = parseMobiBook(bytes);
final fb2 = parseFb2Book(bytes);
final comic = parseComicBook(bytes); // CBZ or supported CBR
final pdf = parsePdfBook(bytes);
final txt = parseTxtBook(bytes);
final html = parseHtmlBook(bytes);
final docx = parseDocxBook(bytes);
final odt = parseOdtBook(bytes);
final azw4 = parseAzw4Book(bytes);

final cb7 = await parseComic7Book(bytes);
final cbc = await parseCbcBook(bytes);
```

CB7 and CBC use an asynchronous 7-Zip reader. `Unseal.parse` and
`Unseal.readMetadataSync` reject those formats; use `Unseal.read`,
`Unseal.readMetadata`, or the dedicated asynchronous functions instead.

For EPUB 3, `EpubBook.navigation` holds the table of contents from the EPUB 3
navigation document when available, with NCX as a fallback. `pageList` and
`landmarks` expose other navigation sections separately. The package also
exposes typed display preferences and accessibility metadata:

```dart
final book = await Unseal.read(bytes);
if (book is EpubBook) {
  print(book.pageList?.navPoints);
  print(book.landmarks.map((landmark) => landmark.types));

  if (book.package is Epub3Package) {
    final epub3 = book.package as Epub3Package;
    print(epub3.renditionSettings.layout);
    if (epub3.spine.items.isNotEmpty) {
      print(epub3.renditionSettings.layoutFor(epub3.spine.items.first));
    }
    if (epub3.metadata is Epub3Metadata) {
      print((epub3.metadata as Epub3Metadata).accessibility.sufficientAccessModes);
    }
  }
}
```

Rendition values come from the OPF and spine. Accessibility values reflect
publisher metadata; Unseal does not certify accessibility.

For fixed-layout EPUBs, the book resolves the rendition, viewport, and
linearity of any reading-order position directly, so a reader does not have to
re-derive the spine path, manifest id, and rendition chain itself:

```dart
if (book is EpubBook) {
  const index = 0;
  print(book.layoutForSpineIndex(index)); // EpubLayout.prePaginated
  print(book.orientationForSpineIndex(index));
  print(book.spreadForSpineIndex(index));
  print(book.pageSpreadForSpineIndex(index)); // synthetic-spread placement
  print(book.viewportForSpineIndex(index)); // EpubViewport(width, height) or null
  print(book.spineItemIsLinear(index)); // false for linear="no" items
  print(book.nonLinearSpinePaths);
}
```

`contentViewports` maps content paths (the same key space as `files.html`) to
the page dimensions declared inside fixed-layout XHTML (`<meta
name="viewport">`) or standalone SVG content documents (root `width`/`height`,
falling back to `viewBox`). Standalone SVG documents join the reading order as
content documents. Malformed, fractional, non-positive, or oversized
declarations yield no viewport instead of failing the parse; only documents the
spine references are scanned.

`BookProgression` measures the full reading order, including non-linear
spine items. Applications that omit auxiliary content must account for that
difference when presenting progress.

### EPUB metadata updates and Calibre catalogs

`updateEpubMetadata` returns new EPUB bytes with selected OPF fields changed.
It does not write the file or change identifiers, the cover, or chapter content:

```dart
final updated = updateEpubMetadata(
  bytes,
  const EpubMetadataUpdate(title: 'A new title'),
);
```

To inspect an existing Calibre library database, read its `metadata.db` bytes
and use the read-only parser:

```dart
final catalog = CalibreDatabase.parse(metadataDbBytes);
for (final entry in catalog.books) {
  print('${entry.title}: ${entry.formats}');
}
```

The Calibre records describe available formats and library-relative paths;
opening a listed book remains the application's responsibility.

### OPDS 2.0 catalogs

`parseOpds2Feed` reads OPDS 2.0 JSON catalogs into a neutral model with
navigation, publications, nested groups, facets, acquisition links with
their properties, and pagination metadata. The existing OPDS 1.x Atom
parser stays unchanged. Both live behind the main entry point and the
narrow `package:unseal/opds.dart`:

```dart
final feed = parseOpds2Feed(feedBytes);
final resolved = resolveOpds2Href(
  feed.nextLink!.href,
  baseUrl: Uri.parse(feedUrl),
);
```

Parsing never fetches: relative links resolve only against a base URL the
caller passes, `borrow`/`buy` relations and prices stay data, and
authentication, purchase, loan, and DRM flows belong to the application.
Bounded input caps (bytes, depth, values, per-collection counts) apply
before allocation and the failures are typed with JSON pointers. The
supported subset, extension policy, and the schema-versus-normative rules
are documented in `doc/opds2.md`.

### EPUB structural diagnostics

`diagnoseEpub` reports structural and reference findings for an EPUB with
stable rule identifiers, severities, resources, locations, and reasons. It
covers the OCF container and rootfile, the OPF manifest, the spine, and
EPUB 2/3 navigation references, including relative paths, percent-encoding,
and fragments:

```dart
final report = diagnoseEpub(bytes);
for (final finding in report.findings) {
  print('${finding.severity.name} ${finding.ruleId}: ${finding.reason}');
}
```

Diagnostics never change what the reading APIs accept or reject, never
repair a book, and never fetch external resources. A report without
findings is not an EPUB conformance claim; the subset is deliberately
narrower than EPUBCheck, and content-document validity, CSS, metadata
formats, and accessibility checks stay out of scope. The rule catalog,
the measured EPUBCheck 5.4.0 mapping, and the report bounds are documented
in `doc/epub-diagnostics.md`.

### Page data for comics and PDFs

`ComicBook.pages` stays in natural archive order. `pageInfo[i]` describes
`pages[i]`: its ComicInfo role, double-page hint, and optional declared
dimensions. `readingDirection` becomes `rightToLeft` only when ComicInfo
explicitly says `Manga=YesAndRightToLeft`. A page marked `Delete` remains in
the list for the application to handle. A declared `FrontCover` is used as the
book cover; otherwise the first page is used.

```dart
final comic = parseComicBook(comicBytes);
print(comic.readingDirection);
for (final page in comic.pageInfo) {
  print('${comic.pages[page.imageIndex].path}: ${page.type}, spread=${page.doublePage}');
}
```

### Structured layout and stable positions for PDFs

Every page exposes a structure with words (real glyph advances, never a
divided line width), text lines and blocks (Docstrum-adapted segmentation),
the reading order with column regions and header/footer roles, and simple
tables (ruled lattices, vertical rulings, or whitespace-aligned columns —
refusals come back as typed diagnoses, never as a silently empty page).
Geometry lives in the cropped, rotated page space, top-left origin, with an
invertible affine back to PDF user space.

```dart
final book = parsePdfBook(bytes) as PdfBook;
final page = buildPdfPageStructure(book: book, pageIndex: 24);
print('${page.words.length} words, ${page.blocks.length} blocks, '
    '${page.columns.length} columns');
for (final region in page.tableRegion?.rows ?? const <List<PdfTableCell>>[]) {
  print([for (final cell in region) cell.text]);
}
// A source anchor survives reopenings and eager/session switches.
final anchor = PdfSourceRange(
  pageIndex: 24,
  lineIndex: 3,
  start: 0,
  end: page.sourceLines[3].text.length,
  expectedLineText: page.sourceLines[3].text,
);
final mapping = page.mapSourceRange(anchor);
if (mapping is PdfPositionMapped) {
  print(page.canonicalText.substring(
      mapping.position.offset, mapping.position.end));
}

// Sessions answer the same model through the worker or isolate.
final structure = await session.loadPdfPageStructure(24);
```

Tables are one region per page in this delivery; multi-table pages keep the
strongest candidate. `snapshots` of a page's canonical text bind the reflow
plan revision, the section occurrence, and the text digest, and
`CanonicalTextCodec` refuses reuse a destination cannot confirm.

Each `PdfPageText` reports `quality`, the number of content streams, and how
many streams could not be decoded. `imageWithoutText` is a useful signal for
an application that offers OCR; it does not prove that a page is a scan.
`columnOrderApplied` indicates that Unseal reordered clearly separated,
text-only columns for reflow and the canonical text stream.

```dart
final pdf = parsePdfBook(pdfBytes);
for (var i = 0; i < pdf.pageTexts.length; i++) {
  final page = pdf.pageTexts[i];
  print('Page ${i + 1}: ${page.quality}, skipped=${page.skippedContentStreams}');
}
```

`DjvuBook.pages` exposes directly stored JPEG pages, decoded JB2 masks as
black-on-white 1-bit BMP images, FGbz per-blit palette colors, and bounded IW44 photo or composed pages as
24-bit BMP images. It preserves dimensions, DPI, rotation, and hidden text:
compressed `TXTz` chunks (preferred over the legacy `TXTa` encoding when a
page stores both) carry the page text in reading order, rendered with the
separator conventions of positional text extraction. A top-level `NAVM`
chunk becomes real navigation; bookmark URLs stay verbatim on each point's
content target. Per-page HTML keeps the text searchable. The complete source
stays in `DjvuBook.bytes` for applications with a dedicated DjVu renderer.
JB2 pages inherit the shared `Djbz` dictionary their `INCL` chunk names —
including documents that switch dictionaries mid-document — and alternate
image codecs that replace a supported layer still fail with typed errors.

The hidden text also decodes as a spatial structure. `DjvuBook.pageStructureAt`
exposes the page's zone tree with the stored coordinates `djvutxt` reports,
plus a top-left projection (region/line/word) whose zones carry canonical
UTF-16 ranges into the page text under the `djvu.hidden-text` extraction
profile. Search indexes built over a DjVu book, zone lookups, and durable
anchors therefore address one text space: an index hit lands inside a word
zone, and an anchor captured from either resolves as verified reuse against
the same revision.

Spatial rectangles use the original page dimensions with a top-left origin;
rotation is separate metadata. A consumer applies that rotation when mapping
the source page into its displayed coordinate system.

## Readium locators and position lists

`ReadiumLocator` imports and exports Locator JSON through the bounded
`readiumLocatorFromJson` and `readiumLocatorToJsonString` APIs. Book and
BookSession conversions to/from native locators return explicit exact,
approximate, ambiguous, or unsupported outcomes. EPUB CFIs must confirm the
addressed href and reading-order occurrence. PDF imports and exports require
a matching host-supplied document URI; comic locators use the page image href.
A locator alone does not verify persisted positions across publication revisions.

`ReadiumPositionListBuilder.ofBook` and `.ofSession` generate deterministic
lists under `unseal.readium.positions/1`: the first position of each reading-order
occurrence and then every 1024 Unicode scalars, or one position per PDF/comic
page. Public offsets remain UTF-16. Session builds report coverage and accept
cancellation; generating a full list can load all text. Limits cap positions
and cumulative text scans. This profile's density is an Unseal policy.
See [the Readium contract](doc/readium-locators.md) for units, formulas,
identity checks, supported mappings, and the independent comparison protocol.

## ALTO OCR import

The main `package:unseal/unseal.dart` entry point also imports ALTO OCR
sidecars into the same spatial contract through `parseAltoDocument` and
`bindAltoToSnapshot`. `package:unseal/alto.dart` is the narrow entry point.
The supported subset covers namespaces v2, v3, and v4; the schema's units
(`pixel`, `mm10`, `inch1200`); pages with dimensions, sequence numbers and
confidence; text, composed, illustration and graphical-element blocks;
lines; and strings with word confidence, character-confidence codes and
substitution content. Coordinates stay in the declared unit — converting a
physical unit requires a verifiable scale (a declared dpi, or page
dimensions agreeing with the target page within 1%), and without one the
conversion refuses with `AltoUnitConversionException` instead of guessing.

`bindAltoToSnapshot` maps the imported words onto a host-provided canonical
text snapshot — the host owns the OCR document's link to a real page;
schema validity alone proves nothing about which book the OCR belongs to.
Each string resolves at the first occurrence at or after a reading cursor;
a repeated quote stays ambiguous with its full candidate list, an absent
word reports missing, and a work budget stops hostile quadratic scans. The
binding preserves the target's identity tuple and the OCR's origin,
software, and confidence. Browser workers serve the same operations through
`UnsealWorker.spatialDjvuPageInWorker` and `UnsealWorker.bindAltoInWorker`.

## PAGE XML import

PAGE OCR sidecars (the PRImA vocabulary) import through the same spatial
contract via `parsePageXmlDocument` and `bindPageToSnapshot`;
`package:unseal/page.dart` is the narrow entry point. The supported subset
is exactly the 2019-07-15 namespace — any other PAGE release refuses with
`PageXmlUnsupportedFeatureException` — validated against the official
schema of that date over a licensed real-corpus lane (the OCR-D
`gt_structure_text` ground truth, CC-BY-SA-4.0) and an independent lxml
extractor whose records the Dart parser is diffed against.

The subset keeps the format's own detail: metadata, page identity and
dimensions, all fifteen region kinds, text lines and words, native
integer polygons and baselines, the reading order with nested ordered
and unordered groups, and `TextEquiv` alternatives with declared index,
confidence and language. Polygons stay native; bounding boxes are the
explicitly derived projection. Orientation stays a display-space hint —
coordinates never rotate; a page-level orientation that is an exact
multiple of 90 degrees projects as the spatial page's rotation, and
fractional skew stays native. Reading order re-sequences text regions
deterministically; references must resolve, regions may not be
referenced twice, and duplicate indexes or cyclic group structure fail
typed.

`bindPageToSnapshot` maps the chosen text onto a host-provided canonical
snapshot at the finest granularity the sidecar declares — words, then
lines whose words carry none, then regions without text-bearing lines.
Repeated quotes stay ambiguous with bounded candidate lists, absent text
reports missing, and a work budget stops hostile scans, exactly like the
ALTO binding. Workers serve `UnsealWorker.bindPageXmlInWorker` against a
resident DjVu page. Unseal does not run OCR.

## hOCR import

hOCR (HTML with an OCR class vocabulary; Tesseract's default rich output)
imports through `parseHocrDocument` and `bindHocrToSnapshot`;
`package:unseal/hocr.dart` is the narrow entry point. The supported
reading subset is pages, content areas, paragraphs, lines and words in
whatever nesting the producer declared — Tesseract, ABBYY, ocropy, kraken
and gcv2hocr shapes all import with the ancestors that are actually
present — plus the producer metadata. Boxes stay integer pixels in the
top-left space; the baseline polynomial, the text angle and every
unconsumed `title` property stay native on the model, with named
projections and no silent rotation. The 0..100 `x_wconf` scale converts
explicitly to the shared 0..1, and a confidence that is absent, unknown
or zero stays three different states. `order` and `cflow` refuse typed:
document order is the only reading order Unseal reconstructs.

`bindHocrToSnapshot` follows the same ambiguity, budget and cursor rules
as ALTO and PAGE XML; a line's region zone is its nearest boxed ancestor
(paragraph, block or page frame), and pages without a usable frame bind
their text but emit no spatial page. Workers serve
`UnsealWorker.bindHocrInWorker` against a resident DjVu page. Unseal does
not run OCR. The subset, title grammar, producer policies, TSV
normalization and limits are specified in `doc/hocr.md`.

## Durable annotations and W3C exchange

Highlights survive edition changes through durable anchors: an additive
envelope that stores a selection's publication identity, source revision,
section occurrence, extraction profile, text revision, UTF-16 bounds and the
quote/context evidence — never the section text itself. The v1 annotation and
locator codecs are untouched; anchors are a separate schema an application
persists beside them.

```dart
final snapshot = DurableAnnotations.sectionSnapshot(
  book,
  sectionIndex: 3,
  identity: identity, // PublicationRevision: namespaced id + verified source revision
);
final anchor = DurableAnnotations.capture(snapshot: snapshot, start: 120, end: 260);
final payload = encodeAnchor(anchor); // versioned, structured-clone-safe map
```

Resolution answers exactly one of `resolved`, `ambiguous`, `missing`,
`incompatibleRevision` or `unsupported`. The full identity tuple decides
verified reuse first; anything else needs an explicit policy:

```dart
final outcome = DurableAnnotations.resolve(
  anchor: anchor,
  targets: DurableAnnotations.sectionSnapshots(revisedBook, identity: revisedIdentity),
  policy: AnchorPolicy.explicitMigration, // same publication, new revision
);
switch (outcome) {
  case AnchorResolved(:final range, :final verified):
    print('${range.text} (verified: $verified)');
  case AnchorAmbiguous(:final candidates):
    print('${candidates.length} indistinguishable candidates');
  case AnchorMissing():
  case AnchorIncompatibleRevision(:final differingFields):
  case AnchorUnsupported():
}
```

The migration ladder re-finds the selection by exact text, then by
whitespace-normalized text (re-wrapped editions), then by a bounded fuzzy
match (corrected editions carry their measured edit distance). Indistinguishable
ties stay ambiguous with the candidate list, even when one candidate appears
earlier in the book — nothing attaches to a passage by picking the first hit.
A removed target is `missing`; another publication id never migrates under any
policy; `AnchorPolicy.contextRecovery` re-finds unverified positions for
anchors whose identity cannot be confirmed, and says so on the outcome. PDF
anchors bind to the page structures' canonical snapshots (one profile per
reading mode), so a selection captured in the session survives the switch to
the full document through migration.

For interchange, the W3C adapter implements a declared subset of the Web
Annotation Data Model: `TextQuoteSelector` (exact/prefix/suffix) and
`TextPositionSelector`. Selector positions count Unicode code points over
normalized text; the conversions project both ways against UTF-16, count astral
characters once and combining marks individually, and refuse a bound inside a
surrogate pair as unrepresentable instead of shifting the target. Context
truncation is reported as a loss; unknown selector types are named by the
support report, never silently dropped. Unknown identity, unverified anchors
and hostile payloads stay bounded: `AnchorLimits` caps quote and context
lengths, candidate counts, scan work and payload sizes, and imports fail typed
(`AnchorCodecException`, `W3cAdapterException`). Anchors without a verified
source revision or a known reading order work in memory and refuse export
instead of inventing identity. There is no annotation UI, sync, storage or
conflict resolution here — applications own those.

## The common book model

Every parser exposes the parts a reading application usually needs:

- `BookMetadata` for title, authors, language, publisher, identifiers,
  subjects, dates, series, and cover data.
- `Files` for HTML content, stylesheets, images, fonts, and binary resources.
- `ReadingOrderItem` and `Navigation` for the spine and table of contents.
- `BookStatistics` and `TextFile.plainText` for word counts and estimated
  reading time.
- Format-specific models such as `EpubBook`, `MobiBook`,
  `DocumentBook`, `ComicBook`, and `PdfBook` when the generic model is
  not enough.

The library also provides reusable reading services:

- Search with plain-text, case-sensitive, whole-word, regex, and proximity
  modes.
- Portable text, page, and EPUB CFI locators.
- Locator serialization and text-locator relocation after content changes.
- Bookmark and highlight codecs for application-owned persistence.
- EPUB CFI resolution and construction.
- OPDS feed parsing: OPDS 1.x Atom and OPDS 2.0 JSON catalogs. Networking and authentication remain the caller's job.
- Bounded format detection before parsing.

## Platform behavior

| Environment | Supported path | Execution notes |
| --- | --- | --- |
| Dart VM | Bytes and filesystem paths | Native asynchronous parsing uses an isolate when the runtime supports it. |
| Flutter Android, iOS, macOS, Linux, and Windows | Bytes and filesystem paths | The library has no Flutter dependency; the repository includes a minimal Flutter example. |
| Browser JavaScript | Bytes only | Without configuration, parsing runs on the browser's main thread. |
| Browser JavaScript with worker | Bytes only | `UnsealWorker` can move normal parsing off the main thread. |
| WebAssembly | Not currently claimed as a verified target | There is no WASM build or compatibility guarantee in the current validation matrix. |

### Browser usage

Browser applications should fetch or otherwise obtain a `Uint8List` and use a
byte-based API. `readFile` and `readMetadataFile` throw
`UnsupportedError` on the web.

To keep large parses off the browser's main thread, compile and serve the
worker entry point:

```sh
dart compile js web/unseal_worker.dart -o <your-web-root>/unseal_worker.js
```

Configure it before opening books:

```dart
import 'package:unseal/unseal.dart';

void configureReader() {
  UnsealWorker.configure(Uri.parse('unseal_worker.js'));
}
```

The worker URL must be reachable under the browser's worker security rules,
including same-origin or CORS requirements. The worker is lazy. If it cannot
be loaded, normal parsing falls back to the main thread. The fallback keeps
the API working but a large book can temporarily block the UI.

The worker receives and returns structured-cloned data. Large books can
therefore temporarily exist in both the worker and the main-thread memory.
CB7 and CBC stay on their asynchronous archive path instead of the normal
worker operation.

## Limitations and security boundaries

### Rendering and fidelity

unseal produces reading data; it does not render pages or provide navigation
controls. DOCX and ODT preserve semantic structure and common formatting, but
complex layouts, footnotes, charts, equations, advanced numbering, fields,
tracked changes, and complex drawing effects can be lost.

PDF support is designed for reading modes and extraction. It is not a promise
of pixel-perfect rendering for every PDF producer. Vector graphics, forms,
annotations, and image codecs outside the supported extraction contract may be
omitted. The original PDF bytes are retained for an application that provides
its own facsimile renderer.

PDF `JPXDecode` images decode through a pure-Dart JPEG 2000 Part 1 subset ported
from a pinned OpenJPEG revision: bare J2K codestreams and JP2 wrappers, unsigned
8- to 16-bit grayscale and RGB, subsampled component grids (`XRsiz`/`YRsiz`,
image origins, odd sizes, partial edge tiles) upsampled to the reference grid,
JP2 sYCC converted to RGB with the reference's 4:4:4, 4:2:2 and 4:2:0 rules,
the reversible 5/3 and irreversible 9/7 wavelets, LRCP and RLCP progression,
single and multiple tiles, RCT and ICT component transforms, custom precincts,
SOP/EPH markers, segmentation symbols, multiple quality layers, COD/COC and
QCD/QCC overrides, and `/ASCII85Decode /JPXDecode` chains. Images above 8 bits
extract as 16-bit PNGs whose samples are bit-replicated and tagged with an
`sBIT` chunk; the native sample planes keep the full precision and 8-bit images
extract byte-identically to previous releases. Lossless decodes are byte-exact
against the OpenJPEG oracle on native samples, upsampled planes and converted
RGB; lossy decodes stay inside ceilings fixed before the first Dart
comparison; VM and compiled-browser decodes are byte-identical. Signed
components, precision outside 8–16 bits, mixed component precisions, arithmetic
coding bypass, Part 2 extensions, CMYK/palette, sYCC chroma layouts outside the
three standard patterns, ICC and calibrated color spaces, `SMaskInData` alpha,
and PDF/codestream geometry conflicts fail typed instead of inventing pixels
(`doc/jpeg2000-precision.md` documents the contract and comparison protocol).

DjVu visual reading covers direct JPEG pages, JB2 masks encoded with direct
symbols, matched refinements, symbol copies, and shared-dictionary
inheritance, plus progressive IW44 `BG44` and `FG44` layers. IW44 supports
v1.0 through v1.2, including photo pages (reduced BG44 layers are expanded
bilinearly), compound color pages selected by an `Sjbz` mask, and `FGbz`
pages whose color recoding is ignored so the mask renders as black ink over
the background. Layer decoding is bounded by chunk, slice, coefficient-work,
cumulative-pixel, and raster-byte limits. `readDjvuMetadata` validates the
container and page INFO without decoding its image layer. Text and pixel
output are cross-checked against djvulibre 3.5.29: page text decodes
byte-identically to `djvutxt` across the tracked public-domain corpus, and
mask and photo pages render byte-identically to `ddjvu`; composed MRC pages
use a deterministic hard mask selection whose bounded channel deviation from
ddjvu's blended stencil is pinned by raster-hash goldens.

TIFF and BigTIFF reading covers multi-page IFD chains in both byte orders and
64-bit BigTIFF offsets, with pages expanded to BMP images. Raster codecs:
uncompressed, PackBits, LZW, and Deflate/AdobeDeflate (with horizontal
differencing predictors, accumulated per 16-bit sample) for gray, RGB, and
bilevel samples; CCITT modified Huffman, Group 3, and Group 4 through a
strict row-oriented T.4/T.6 decoder (including EOL-less producers and a
Group 4 page decoded pixel-identically against libtiff); JPEG passthrough
when a page holds a single self-contained strip. Pages may be stripped or
tiled: tile grids decode every tile at its full footprint (edge tiles
included) before the page takes the visible part, tile addresses are read
from `TileOffsets`/`TileByteCounts` or, as Silicon Graphics files wrote
them, from the strip tags, CCITT tiles decode at the tile width, and
Orientation 2-4 are flipped to top-left. Old-style bit-reversed compat LZW
decodes through libtiff's detection heuristic. Two more raster layouts
decode ([doc/tiff-planar-palette.md](doc/tiff-planar-palette.md)): planar
RGB (`PlanarConfiguration` 2, unsigned 8/16-bit, three planes, by strips or
tiles, with Predictor 2 differencing on a one-sample stride per plane,
band arrays validated across planes before any band decodes), and palette
pages (1/2/4/8-bit indices through an exact-size ColorMap of three 16-bit
tables, native values preserved and compared before libtiff's fixed
display projection: byte-range legacy tables used directly, full-range
tables take the high byte). Layouts outside the contract fail with
`TiffUnsupportedCodecException`: planar pages with alpha or extra samples,
planar CCITT/JPEG, 16-bit palettes, palette + Predictor 2, palette + CCITT,
float/SampleFormat 2/3/5/6, LogLuv, JPEG tiles and JPEGTables-abbreviated
strips, old-style JPEG, reversed FillOrder under any codec, transposed
Orientation 5-8, and uncompressed-mode extensions; malformed containers,
ColorMaps with a wrong entry count, addresses that overlap each other or
the directory (bands included), and oversized tiles fail with
`TiffException` before any declared allocation. Pixels are verified sample
by sample against libtiff 4.7.2 over the tracked strip, tiled, and
planar/palette corpora (SGI-written tiled files, libtiff test images, and
identified `tiffcp` derivatives; see `doc/tiff-tiles.md`,
`doc/tiff-planar-palette.md`, and `test/resources/tiff/PROVENANCE.md`).

### Input and archive boundaries

EPUB diagnostics preflight XML at 16 MiB, 128 nesting levels, and one million
elements per resource. ALTO validates finite geometry and bounds XML nesting
and element counts before building its tree. PAGE XML preflights the same
way (32 MiB input, 128 levels, bounded elements per page) and caps regions,
lines, words, polygon points, TextEquiv alternatives, reading-order
entries and group depth before any allocation; references, id collisions
and confidence ranges validate before the model exists.

- Every ZIP-backed format goes through the same bounded decoder. Before
  inflation, unseal rejects containers declaring more than 1 GiB in total,
  entries larger than 512 MiB, or an expansion ratio above 200x once the
  declared output exceeds 32 MiB. The materialized output is bounded again,
  so forged central-directory sizes cannot bypass the limit. Encrypted
  entries, symbolic links, and compression methods other than stored or
  deflated are rejected with `InvalidBookException`.
- CBR supports a deliberate subset of RAR. RAR 5 headers verify their
  CRC-32; a declared data CRC-32 (zero included) verifies after decode,
  and a declared extra-area BLAKE2sp digest (hash type 0) verifies
  before any payload or solid-chain dependency publishes — both
  checksums when both are present, failures named per cause. RAR 5
  decoding allocates the declared output before decompressing and
  rejects dictionaries above 64 MiB. Unsupported compression modes,
  split archives, links, and encrypted entries are rejected. Solid RAR 5
  chains decode in container order with one dictionary per reader or
  session; opening a solid CBR decodes every compressed page
  sequentially while the session sniffs page types (measured by
  `tool/rar5_bench.dart --solid`), and backward page access replays
  through bounded checkpoints under a cumulative replay budget, so a
  session cannot accumulate unbounded replay work.
- CB7 entries are bounded and parsed asynchronously. Unsupported codecs and
  encrypted entries are rejected.
- AZW4 requires an unencrypted PDF payload. EPUB font obfuscation supports
  only the standard IDPF and Adobe algorithms.
- HTMLZ selects one top-level HTML spine file. Other HTML files remain
  resources.
- TXT/TXTZ conversion covers basic Markdown/Textile constructs, not every
  extension of either format.
- Standalone Markdown input is limited to 16 MiB and front matter to 16 KiB.
  Relative image paths stay in the generated HTML; the parser does not load
  neighboring files. Markdown HTML is not sanitized.
- RTF input is limited to 64 MiB, group depth to 128, and generated HTML to
  64 MiB. Embedded pictures and advanced layout are skipped. High bytes in
  unsupported declared codepages are rejected; Unicode escapes still work.
- PalmDOC input is limited to 64 MiB, with each text record limited to
  4096 decoded bytes. Unsupported Palm database ebook subtypes are rejected.
- eReader PDB input is limited to 64 MiB, 8192 records, 8192 compressed bytes
  and 65535 decoded bytes per text record. DRM-protected books are rejected.
- Plucker PDB input is limited to 64 MiB, 8192 records, 8192 compressed bytes
  and 32768 decoded bytes per text record. Images are limited to 512 records,
  480,000 source bits per bitmap, 60,000 source bytes per bitmap, and 32 MiB
  of generated PNG output.
- CHM input is limited to 128 MiB, individual entries to 16 MiB, directory
  entries to 10,000, and total materialized content to 128 MiB. Unsupported
  LZX layouts and malformed directory/reset tables fail with typed errors.
  LZX work is capped at 8192 decoded frames, with frames reused within a
  reset interval. Intel E8 addresses are restored per frame. Windows-1251,
  Windows-1252, and Windows-1256 are selected from supported `#SYSTEM` locale
  IDs; other encodings use the shared text detector.
- DjVu input is limited to 128 MiB, 1024 pages, 65536 IFF chunks, 100 million
  declared pixels per page, 32 MiB per directly stored JPEG, and 8 MiB per
  OCR chunk (uncompressed TXTa or BZZ-decompressed TXTz). JB2 decoding further
  caps a mask at 16 megapixels, one symbol at 4 megapixels, cumulative symbol
  decoding and blitting at 64 megapixels each, stored symbols at 16 megapixels
  total, records at 65536, arithmetic-number context nodes at 1,048,576, and
  comments at 64 KiB. Shared dictionaries add a 64-megapixel per-document cap
  charged before each symbol bitmap is allocated; a shared dictionary that
  itself inherits another dictionary is rejected typed. BZZ streams (TXTz, NAVM,
  DIRM names) validate every declared block size against the 4 MiB format
  limit and the chunk's output cap before allocating, and NAVM record streams
  are bounded by their 16-bit bookmark count with child claims verified
  against the record pool. Across one document, decoded visual layers are
  limited to 2048 million pixels and 1 GiB of materialized raster bytes —
  sized for real scanned books, which the speller corpus document approaches
  at 1.4 gigapixels; each page reserves this budget before its decoder
  allocates output. Indirect document directories are rejected over bytes and
  resolved only by the file-based open path, which loads DIRM-named sibling
  components (plain file names only, declared sizes matched) from the
  document's own directory.
- DjVu chunks that neither carry displayable content nor replace a supported
  layer are ignored: `ANTz`/`ANTa` annotations, `CIDa` identifiers, `TH44`
  thumbnails and `BMKz` compressed bookmarks. FGbz v0 palettes and per-blit indices recolor supported JB2 masks; palette-only chunks keep black ink. Duplicate foregrounds and invalid counts fail typed. See `doc/djvu-fgbz.md` for the separate native-foreground and hard-mask composition contracts. Chunks
  that replace a supported layer — `Smmr` MMR masks and `FGjp` JPEG foregrounds —
  fail with `DjvuUnsupportedCodecException`. Measured across the tracked corpus and the
  1,196-page stress set, these cover every chunk observed in the wild except
  the supported ones; `BMKz`, `TXTa`, `BGjp`, `FGjp`, and `Smmr` never appear
  in the corpus files.
- LRF input is limited to 128 MiB, 20,000 indexed objects, 10,000 pages,
  32 MiB per expanded stream, 64 MiB of total expanded content, 4 Mi code units
  of rendered HTML per page, and 64 Mi code units of rendered HTML per book.
- LRX2 metadata reads are limited to 128 MiB and 1,024 outer boxes. The parser
  rejects LRX book content as DRM-protected and does not process its protected
  payload.
  Unsupported tags and stream flags fail with typed exceptions.
- TIFF/BigTIFF input is limited to 128 MiB, 1,024 pages, 65,536 IFD entries,
  4 samples per pixel, a 256-megapixel page or tile footprint, a million
  strips or tiles per page, 256 megapixels of decoded pixels per document,
  128 MiB of resident decoded bytes per document (page images plus the live
  RGB conversion and segment scratch buffers), and 512 MiB of decode work per
  document counted at full strip/tile footprints. Strip and tile offsets and
  byte counts are validated against the file bounds, the header, the page's
  directory, and each other before any allocation; Deflate segments inflate
  straight into their footprint and stop there; IFD chains are cycle-checked.
  Unsupported codecs and layouts fail with typed exceptions.
- EPUB navigation is optional. A damaged or missing table of contents can
  produce an empty navigation model while readable spine content remains
  available.
- Generic archive formats do not all share the same repository-defined
  resource budget. Format-specific limits are intentional safeguards, not a
  universal guarantee for arbitrary input sizes.

Some examples of explicit adapter budgets are a 64 MiB plain-text limit, a
128 MiB TXTZ input limit, a 128 MiB CB7 entry limit, and a 512 MiB AZW4
container/PDF limit. These values are implementation safeguards and may
change with future releases.

### Content safety

HTML is preserved rather than sanitized. Applications must sanitize or isolate
untrusted HTML before inserting it into a privileged web view or native HTML
component.

DRM is not bypassed. DRM-protected MOBI/AZW3 books, unsupported EPUB
encryption, and encrypted archive entries are rejected. Supported PDF
standard-security documents can be opened with the correct password. After a
successful open, Unseal does not enforce or expose copy, print, or extraction
permission flags.

## Errors

The public API uses typed exceptions so callers can distinguish unsupported
input from corrupted or protected content. Common types include:

- `FormatNotSupportedException` for unknown formats or known formats outside
  the supported contract.
- `InvalidBookException` for corrupted input of a detected format.
- `DrmProtectedException` for rejected DRM-protected books.
- `ComicException`, `Comic7Exception`, `DocxException`, `HtmlException`,
  and `OdtException` for format-specific failures.
- `PdfException` and `PdfEncryptedException` for PDF structure and security
  failures.
- `DjvuException` for malformed or excessive DjVu input and
  `DjvuUnsupportedCodecException` when a page cannot be displayed.
- `AltoException` for malformed or excessive ALTO input,
  `AltoUnsupportedFeatureException` for namespaces, versions or units
  outside the supported subset, and `AltoUnitConversionException` when a
  physical-unit conversion lacks verifiable scale.
- `PageXmlException` for malformed, excessive, or inconsistent PAGE XML
  and `PageXmlUnsupportedFeatureException` for namespaces or versions
  outside the 2019-07-15 subset.
- `HocrException` for malformed, excessive, or inconsistent hOCR input
  and `HocrUnsupportedFeatureException` for an `order` or `cflow`
  reading order.
- `EpubException`, `MobiException`, and `Fb2Exception` for parser-specific
  errors.

Empty inputs, corrupt ZIP containers, and excessively deep PDF or FB2
structures are normalized to these typed failures instead of leaking parser
implementation errors such as `RangeError`, `FormatException`, or stack
overflows.

## Design principles and inspirations

The project is guided by a few practical goals:

1. Preserve usable reading content when optional metadata or navigation is
   damaged.
2. Give applications one predictable model instead of one renderer contract
   per file format.
3. Prefer portable pure-Dart implementations over platform executables.
4. Put explicit bounds around decompression, image decoding, and recovery
   where an adapter needs protection from malformed or unusually large input.
5. Keep format specifications, behavioral compatibility references, and
   implementation dependencies visibly separate.

Compatibility work draws on:

- Observable metadata and conversion conventions from Calibre's
  [TXT](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/ebooks/conversion/plugins/txt_input.py),
  [HTMLZ](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/ebooks/conversion/plugins/htmlz_input.py),
  [AZW4](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/ebooks/conversion/plugins/azw4_input.py),
  and [comic](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/ebooks/conversion/plugins/comic_input.py)
  importers. Calibre is GPLv3 and is a behavioral reference, not a runtime or
  source-code dependency. Unseal's implementations are independent pure Dart.
- [Microsoft Open XML package guidance](https://learn.microsoft.com/en-us/office/open-xml/general/how-to-create-a-package)
  for DOCX parts and relationships.
- [`koni_archive`](https://github.com/zenbaku/koni_archive) for the pure-Dart
  7-Zip implementation used by CB7 and CBC.
- PDF.js and Poppler as independent references for PDF extraction and image
  behavior.
- The [Hypothesis client](https://github.com/hypothesis/client/tree/a7b7400d0d706d4357ec37c2a3610b25dcca89d5)
  anchoring (BSD-2-Clause) as the behavioral starting point for durable
  annotation re-anchoring, compared case by case against its DOM-free
  `matchQuote` by `tool/hypothesis_anchor_compare.dart`, with deliberately
  stricter ambiguity handling, and
  [Readium Kotlin](https://github.com/readium/kotlin-toolkit/tree/89b96c20c447d0aec17db57a06456b7decffde4c)
  (BSD-3-Clause) as the identity/locator layering reference. Neither is a
  runtime or source dependency; nothing here claims Readium or full W3C
  conformance.
- The [W3C Web Annotation Data Model](https://www.w3.org/TR/annotation-model/)
  as the external contract for the TextQuoteSelector/TextPositionSelector
  subset of the exchange adapter.
- The [DjVu 3 specification](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf)
  for IFF structure, JB2 records, ZP coding, and the BZZ byte stream (BWT,
  modified MTF-4, and the 262-context decision tree). JB2 ZP state-table
  constants and the BZZ decode order were cross-checked against the
  independent [MIT-licensed djvu-rs
  implementation](https://github.com/matyushkin/djvu-rs/tree/main/crates/djvu-zp);
  its notice is in `licenses/djvu-rs-MIT.txt`. No DjVuLibre GPL source is
  copied into this parser; behavioral parity comes from the spec plus the
  public-domain corpus verified against local djvulibre renders.

## Development

Use a source checkout and the SDK pinned in `.dart-version`:

```sh
dart pub get --no-example
dart analyze --fatal-infos
dart test --exclude-tags fuzz
```

The [development guide](doc/development.md) covers browser workers, fuzz,
fixture provenance, performance measurements, and the release commands.
Read the [architecture](doc/architecture.md) before changing module or
safety boundaries. Use the [codebase guide](doc/unseal-codebase-guide.md)
to find a format's implementation and the [roadmap](doc/roadmap.md) for
pending work.

The [Flutter example](example/README.md) demonstrates the public API by
loading a bundled EPUB and showing its parsed summary.

## License

MIT
