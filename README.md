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
FB2, TXT, HTML, CHM, DOCX, ODT, AZW4, comic
archives, PDF, and JPEG-backed DjVu pages without a native executable, FFI bridge, or Flutter
dependency in the library itself.

Unseal is a parser and data layer, not a reader UI or a general-purpose
document renderer.

## At a glance

- One API for metadata-only scans and full book parsing.
- Common models for metadata, HTML content, stylesheets, images, fonts,
  navigation, covers, and reading order.
- Format detection, full-text search, reading progression, portable locators,
  EPUB CFI operations, annotation codecs, and OPDS feed parsing.
- Pure Dart on the Dart VM, Flutter native targets, and browser JavaScript.
- Optional web-worker parsing for browser applications.
- Typed exceptions and format-specific recovery paths for damaged input.

## Supported formats

| Format | Main capabilities | Important boundary |
| --- | --- | --- |
| EPUB 2/3 | OPF metadata, spine, XHTML, CSS, images, fonts, media overlays, navigation, and CFI; EPUB 3 page list, landmarks, rendition, and accessibility metadata | Font obfuscation is limited to the standard IDPF and Adobe algorithms. |
| KEPUB | Kobo EPUB packages are read through the EPUB parser, preserving Kobo spans and EPUB content. | Reported as `BookFormat.epub`; a Kobo-specific format type is not inferred from ZIP bytes. |
| MOBI 6 | PalmDOC and HUFF/CDIC decompression, EXTH metadata, chapters, images, fonts, and navigation | DRM-protected books are rejected. |
| PalmDOC PDB | Uncompressed or PalmDOC-compressed `TEXt/REAd` records, title, and plain reading text | Other PDB ebook families use separate parsers. |
| eReader PDB | Unencrypted `PNRd/PPrs` text records with PalmDOC or zlib compression and title/author metadata | PML is reduced to reading text; images, footnotes, sidebars, links, and page layout are not converted. |
| Plucker PDB | `Data/Plkr` text pages with PalmDOC or zlib compression and database title | Inline formatting and links are flattened to text; images, bookmarks, and owner-keyed documents are not converted. |
| AZW3 / KF8 | Skeleton and `div` reassembly, FDST flows, CSS/SVG, images, NCX navigation, and joint MOBI/KF8 files | DRM-protected books are rejected. |
| FB2 / FBZ | Metadata, covers, declared encodings, notes, links, styles, and section navigation | The result is a reflowable HTML representation. |
| TXT / TXTZ | UTF-8/UTF-16 decoding, paragraph-preserving XHTML, archive resources, and basic Markdown/Textile | Not a full Markdown or Textile implementation. Plain TXT metadata is limited. |
| Standalone Markdown | CommonMark blocks and inline formatting, headings, links, and simple front matter | Byte-only calls use `parseMarkdownBook`; `readFile` recognizes `.md`, `.markdown`, and `.mdown`. Relative resources are references, not extracted files. |
| RTF | Text, title/author, paragraphs, Unicode, codepages 1251/1252/1256 and UTF-8, and basic emphasis | Tables, pictures, drawing objects, fields, and page layout are not converted. |
| HTML / HTMLZ | Source-preserving HTML, head metadata, heading navigation, OPF manifests, and resources | HTML is preserved, not sanitized. |
| CHM | ITSF directory, LZX-compressed HTML topics and resources, `#SYSTEM` title/home, and nested `.hhc` contents | Reading HTML and resources; no full-text index, merged help collection, or execution of embedded scripts. |
| DOCX | Open XML document structure, styles, headings, lists, tables, links, properties, and images | Semantic conversion; not pixel-perfect Word layout. |
| ODT | OpenDocument paragraphs, headings, styles, lists, tables, images, links, and metadata | Semantic conversion; not pixel-perfect LibreOffice layout. |
| AZW4 | PalmDB/MOBI wrapper validation, PDF extraction, metadata, pages, and original PDF bytes | Requires a valid, unencrypted PDF payload. |
| CBZ | ZIP comic pages, `ComicInfo.xml` reading direction and page roles, natural ordering, and declared front cover | Page-oriented data; no comic UI is included. |
| CBR | RAR 4 stored and ordinary non-solid method-29 entries, plus RAR 5 stored entries | Split, solid, encrypted, PPMd, VM, and other unsupported variants are rejected. |
| CB7 | 7-Zip comic pages, `ComicInfo.xml` reading direction and page roles, natural ordering, and declared front cover | Asynchronous only; encrypted or unsupported entries are rejected. |
| CBC | Top-level `comics.txt` collections containing CBZ, CBR, or CB7 files | The collection is flattened into one `ComicBook` page sequence. |
| PDF | Metadata, bookmarks, page text with extraction diagnosis, conservative two-column reflow, facsimile data, and JPEG/CCITT/JBIG2 images | Reading-oriented extraction, not OCR or a general-purpose PDF renderer. |
| DjVu (JPEG pages) | Single-page and bundled documents with direct `BGjp` JPEG page images, INFO dimensions and rotation, and optional uncompressed `TXTa` OCR | Common JB2/IW44 image layers, compressed `TXTz`/`NAVM`, and indirect documents are not decoded; full opening fails with a typed error rather than returning invisible pages. |

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
  unseal: ^1.1.0
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

Rendition values come from the OPF and spine. Page dimensions declared inside
XHTML or SVG content are not extracted by these properties. Accessibility
values reflect publisher metadata; Unseal does not certify accessibility.

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

Each `PdfPageText` reports `quality`, the number of content streams, and how
many streams could not be decoded. `imageWithoutText` is a useful signal for
an application that offers OCR; it does not prove that a page is a scan.
`columnOrderApplied` indicates that Unseal reordered clearly separated,
text-only columns for reflow and the canonical text stream.

`DjvuBook.pages` exposes directly stored JPEG pages with their original
dimensions, DPI, rotation, and optional uncompressed OCR text. Its
`readingOrder` points to per-page HTML that displays each image and keeps OCR
searchable. The complete source stays in
`DjvuBook.bytes` for applications with a dedicated DjVu renderer. Metadata
scans can identify documents with other DjVu image codecs, but full opening
rejects them until those decoders are available.

```dart
final pdf = parsePdfBook(pdfBytes);
for (var i = 0; i < pdf.pageTexts.length; i++) {
  final page = pdf.pageTexts[i];
  print('Page ${i + 1}: ${page.quality}, skipped=${page.skippedContentStreams}');
}
```

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
- OPDS feed parsing. Networking and authentication remain the caller's job.
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

DjVu visual reading currently covers direct JPEG background pages only. Most
scanned DjVu books use JB2 or IW44 compression, which this release does not
decode. `readDjvuMetadata` validates their container and page INFO structure;
`parseDjvuBook` reports `DjvuUnsupportedCodecException` for those pages.

### Input and archive boundaries

- Every ZIP-backed format goes through the same bounded decoder. Before
  inflation, unseal rejects containers declaring more than 1 GiB in total,
  entries larger than 512 MiB, or an expansion ratio above 200x once the
  declared output exceeds 32 MiB. The materialized output is bounded again,
  so forged central-directory sizes cannot bypass the limit. Encrypted
  entries, symbolic links, and compression methods other than stored or
  deflated are rejected with `InvalidBookException`.
- CBR supports a deliberate subset of RAR. Unsupported compression modes,
  solid or split archives, and encrypted entries are rejected.
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
  and 32768 decoded bytes per text record. Text-only projection omits images.
- CHM input is limited to 128 MiB, individual entries to 16 MiB, directory
  entries to 10,000, and total materialized content to 128 MiB. Unsupported
  LZX layouts and malformed directory/reset tables fail with typed errors.
- DjVu input is limited to 128 MiB, 1024 pages, 65536 IFF chunks, 100 million
  pixels per page, 32 MiB per directly stored JPEG, and 8 MiB per
  uncompressed OCR chunk. Indirect DjVu
  documents require external component files and are rejected.
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
- The [DjVu 3 specification](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf)
  for IFF structure, page INFO, direct JPEG, and OCR chunks; no DjVuLibre GPL
  code is copied into this parser.

## Development

Install dependencies, analyze the package, and run the test suite:

```sh
dart pub get
dart analyze
dart test
```

The default suite is the fast release gate. The deterministic extended fuzz
campaign is opt-in:

```sh
dart test --tags fuzz
dart run tool/fuzz_corpus_inventory.dart --check-manifest
```

Tracked seeds and generated cases live under `test/resources/fuzz/`; their
manifest records sizes, hashes, format families, and structural landmarks.
The same mutation seed always produces the same bytes, while parsing runs in
killable isolates with deadlines so a hang cannot stall the test process.

The benchmark suite measures detection, full parsing, metadata-only reads,
isolate entry points, and lazy getters against the repository fixtures:

```sh
dart run benchmark/unseal_benchmarks.dart --quick
dart run benchmark/unseal_benchmarks.dart
dart run benchmark/unseal_benchmarks.dart --json=artifacts/current.json
dart run benchmark/compare_baselines.dart artifacts/baseline.json artifacts/current.json
```

Benchmark results depend on the machine. Compare runs from the same machine
when evaluating a change. The benchmark matrix covers all 16 supported
formats and emits versioned JSON reports. For a private Calibre library, the
explicitly opt-in `benchmark/library_sweep.dart` tool performs read-only,
timeout-bounded inventory, sweep, and stratified-sample runs. It never writes
to the library and requires a random-ID map outside the repository so paths,
titles, authors, and file names do not enter reports.

```sh
dart run benchmark/library_sweep.dart inventory --library=/books --id-map=/private/library-ids.json --out=artifacts/inventory.json
dart run benchmark/library_sweep.dart sweep --library=/books --id-map=/private/library-ids.json --checkpoint=artifacts/sweep.checkpoint.json --out=artifacts/sweep.json
```

CI runs the release suite separately on the Dart VM and in Chrome to exercise
both native and browser implementations.

The [`example/`](example/) directory contains a minimal Flutter app that loads
the bundled Alice in Wonderland EPUB and displays a parsed summary. It is a
starting point for integration, not a complete reader application.

## License

MIT
