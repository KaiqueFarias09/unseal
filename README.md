# eLivre

eLivre is a pure-Dart book parsing library. Give it bytes or a file and
get one format-agnostic `Book` model with metadata, cover, reading order,
navigation, text, stylesheets, fonts and images. It supports **EPUB
2.0/3.0**, **MOBI**, **AZW3 (KF8)**, **FB2/FBZ**, **TXT/TXZ**,
**HTML/HTMLZ**, **DOCX**, **AZW4**, **CBZ/CBR/CB7/CBC**, **ODT** and **PDF**
without native dependencies.

The library is a parser and reading-data layer, not a visual reading app.
The `e_livre_viewer` package can consume the parsed books and provide the
reader UI.

## Supported formats

| Format | What eLivre supports |
| --- | --- |
| EPUB 2 and 3 | Package metadata, spine and reading order, HTML/XHTML (including common `text/html` variants), CSS, images, fonts, UTF-16 XML, navigation fallback, media overlays and EPUB CFI operations. It also recovers usable OPF packages without `container.xml`, chooses a valid rootfile and decodes IDPF/Adobe font obfuscation. |
| MOBI 6 | PalmDoc and HUFF/CDIC decompression, EXTH metadata, chapters, images, fonts and file-position navigation. |
| AZW3 (KF8) | Skeleton/div reassembly, FDST flows, CSS/SVG, CONT/CRES image containers, NCX navigation and joint MOBI 6 + KF8 files. |
| FB2 and FBZ | Metadata, cover binaries, declared XML encodings, body-to-XHTML conversion, preserved stylesheets and named styles, notes, internal links and section navigation. |
| TXT and TXTZ | UTF-8/UTF-16 text, paragraph-preserving XHTML, metadata-only reads, optional Calibre-style `metadata.opf`, multiple TXTZ sections, natural order, CSS, images, fonts and basic Markdown/Textile formatting. |
| HTML and HTMLZ | Source-preserving HTML/HTM/XHTML, head metadata and heading navigation. HTMLZ follows the top-level `index.*` convention, reads OPF as metadata/manifest and extracts resources. |
| DOCX | Open XML `word/document.xml`, core properties, styles, basic run formatting, headings, lists, tables, hyperlinks, relationships and embedded images. |
| AZW4 | Validated PalmDB/MOBI wrapper with PDF record extraction, PDF metadata/pages/reflow and original PDF bytes retained for a viewer. DRM is rejected. |
| CBZ | ZIP comic pages, `ComicInfo.xml` metadata, deterministic natural page ordering across mixed directory depths and the first page as cover. |
| CBR | RAR 4 stored entries and ordinary non-solid RAR 4 method-29 entries, plus RAR 5 stored entries with extra header areas. |
| CB7 | 7-Zip comic pages, `ComicInfo.xml` metadata, natural page ordering and the first page as cover. |
| CBC | Calibre comic collections described by top-level `comics.txt`, resolving nested CBZ, CBR and CB7 files in declaration order. |
| ODT | OpenDocument XML paragraphs, headings, inline styles, links, lists, tables, images and document metadata converted to the common reflow model. |
| PDF | Structure, metadata, bookmarks, page text, bounded preamble recovery, canonical reflow HTML, facsimile data and extracted JPEG, CCITT and JBIG2 page images. |

`OPF` is not a standalone reading format in eLivre. When it appears as
`metadata.opf` inside TXTZ/HTMLZ, it is treated as a metadata and manifest
sidecar, as in Calibre.

## Why use it

- One API for metadata scanning, full parsing and format-specific access.
- Pure Dart with no native dependency, suitable for Dart VM, Flutter and
  browser applications. CB7/CBC use the pure-Dart `koni_archive` 7-Zip
  reader; no platform executable or FFI bridge is required.
- A metadata-only path avoids extracting content when a library only needs
  title, author, language, cover or series information.
- Native parsing runs in a background isolate. Web applications can opt into
  the bundled worker and automatically fall back to inline parsing.
- PDF text has one canonical character space across extraction, reflow,
  search, locators and the viewer's reading modes.
- Portable locators, EPUB CFI ranges, search modes, reading progression and
  annotation codecs are available independently of a particular UI.
- Parsing failures use typed exceptions, and bounded PDF/JBIG2/CCITT work
  protects callers from malformed or hostile input consuming unbounded
  memory or CPU.
- Office and archive formats are converted into one `DocumentBook` contract,
  so a viewer can reuse its existing HTML, resource, navigation and search
  pipeline instead of implementing a renderer per format.

## Features

- Format detection by signatures and bounded content inspection (`epub`,
  `mobi`, `azw3`, `fb2`, `txt`, `html`, `docx`, `odt`, `azw4`, `cbz`,
  `cbr`, `cb7`, `cbc`, `pdf`).
- Metadata-only fast path: title, authors, languages, publisher,
  ISBN, subjects, dates, identifiers, series and cover without
  extracting the book content.
- **Calibre integration**: a sibling `<basename>.opf` / `metadata.opf`
  sidecar merges over the book's own metadata, and books without any
  metadata fall back to the `Title - Author.ext` filename pattern.
- Full parse with parity across formats: HTML content files, CSS,
  images, fonts and the table of contents.
- Recovery is deliberately format-aware: stale EPUB navigation can fall
  back to a valid EPUB 3 nav document, optional MOBI EXTH metadata can be
  ignored when damaged, and readable content is preserved when package
  metadata is incomplete.
- Reading statistics: `book.statistics` gives word count and
  estimated reading time; `TextFile.plainText` extracts clean text.
- Cover dimensions parsed from image headers (JPEG/PNG/GIF/BMP/WebP)
  without decoding.
- MOBI 6 books split into `MobiBook.chapters` at the TOC anchors.
- MOBI internals implemented from scratch: PalmDoc and HUFF/CDIC
  decompression, EXTH metadata, KF8 skeleton/div reassembly, FDST
  flows, CONT/CRES image containers and NCX navigation, including
  joint MOBI 6 + KF8 files.
- FB2 body-to-XHTML conversion with notes bodies and section-based
  navigation; zipped FB2 (`.fbz`) supported.
- Comics: CBZ (with `ComicInfo.xml` metadata) and CBR (RAR 4 stored or
  ordinary non-solid method-29 entries, and RAR 5 stored entries), pages
  in natural order, first page as cover.
- TXT/TXZ: safe text-to-XHTML conversion, BOM-aware decoding, Calibre OPF
  sidecars, Markdown/Textile basics and archive resource extraction.
- HTML/HTMLZ: source-preserving HTML, metadata/head parsing, heading-based
  navigation, top-level index selection and OPF manifest/cover handling.
- DOCX/ODT: interoperable XML-to-XHTML conversion with common document
  structure, metadata, images and tables.
- AZW4: PDF wrapper extraction with DRM detection and reuse of the existing
  PDF reading pipeline.
- CB7/CBC: pure-Dart 7-Zip comics and Calibre collection manifests. Their
  asynchronous parser is available through `openFromBytes` and the dedicated
  `parseComic7Book` / `parseCbcBook` entry points.
- PDF structure, text extraction, Calibre-inspired reflow, bookmarks,
  standard security-handler revisions 2 through 6, and CCITT/JBIG2 image
  decoding. JPEG XObjects are preserved byte-for-byte for the viewer.
- Format-neutral search, progression, locators and portable annotations,
  plus EPUB CFI resolution and optional OPDS feed parsing.
- Parsing runs in a background isolate when available (Flutter apps
  stay responsive); on the web an opt-in web worker does the same,
  with inline parsing as the fallback.

## Getting started

```yaml
dependencies:
  e_livre: ^3.3.0
```

## Usage

Open any supported book and work with it generically:

```dart
import 'package:e_livre/e_livre.dart';

final book = await BookReader.openFromPath('/books/wonderland.azw3');

print(book.format.name);            // azw3
print(book.metadata.title);         // Alice's Adventures in Wonderland
print(book.metadata.authors);       // [Lewis Carroll]
print(book.metadata.series);        // series name, when known
print(book.metadata.cover?.bytes);  // cover image bytes
print(book.metadata.cover?.width);  // pixel dimensions from headers

print(book.navigation.navPoints);   // table of contents
print(book.files.html);             // content files
print(book.files.css);              // stylesheets
print(book.files.fonts);            // fonts
print(book.files.images);           // images

final stats = book.statistics;
print(stats.wordCount);                        // ~26k
print(stats.estimatedReadingTime().inMinutes); // ~132
```

Or switch on the concrete type for format-specific access:

```dart
switch (book) {
  case EpubBook epub:
    print(epub.version);        // 3.0
    print(epub.package);        // parsed OPF package
  case MobiBook mobi:
    print(mobi.chapters.first.title); // MOBI 6 chapter split
  case Fb2Book fb2:
    print(fb2.files.html.first.content);
  case ComicBook comic:
    print(comic.pageCount);     // pages in natural order
  case DocumentBook document:
    print(document.files.html); // TXT, HTML, DOCX and ODT content
  case PdfBook pdf:
    print(pdf.pageCount);       // PDF and AZW4 page count
}
```

Only need metadata (e.g. for a library scanner)? Skip the content
extraction entirely — path-based reads also apply Calibre sidecar
OPFs and the filename fallback:

```dart
final metadata = await BookReader.readMetadataFromPath(path);
print(metadata.title);
print(metadata.cover?.mimeType); // image/jpeg
```

Format-specific entry points are still available:

```dart
final anyBook = await BookReader.openFromPath(file.path); // every supported format
final mobi = parseMobiBook(bytes);            // MOBI / AZW3
final fb2 = parseFb2Book(bytes);              // FB2 / FB2.zip
final comic = parseComicBook(bytes);          // CBZ / CBR
final pdf = parsePdfBook(bytes);               // PDF
final txt = parseTxtBook(bytes);              // TXT
final html = parseHtmlBook(bytes);            // HTML / XHTML
final docx = parseDocxBook(bytes);            // DOCX
final odt = parseOdtBook(bytes);              // ODT
final azw4 = parseAzw4Book(bytes);            // AZW4 wrapper
final cb7 = await parseComic7Book(bytes);     // CB7 (async 7z reader)
final cbc = await parseCbcBook(bytes);        // CBC (async collection)
```

## Web support

The library is pure Dart and runs on every target: native (VM),
JavaScript and WebAssembly. Everything is driven by bytes, so the
browser flow is `fetch` (or a file picker) straight into the reader:

```dart
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'package:e_livre/e_livre.dart';

Future<Uint8List> fetchBookBytes(String url) async {
  final promise = globalContext.callMethod('fetch'.toJS, url.toJS) as JSPromise<web.Response>;
  final response = await promise.toDart;
  final buffer = await response.arrayBuffer().toDart;

  return JSUint8Array(buffer).toDart;
}

final book = await BookReader.openFromBytes(await fetchBookBytes('books/wonderland.epub'));
```

Path-backed APIs (`openFromPath`, `readMetadataFromPath`) have no
meaning in a browser and reject with `UnsupportedError` there; the
Calibre sidecar lookup is filesystem-only and skips itself on the web.
`dart test test/web --platform chrome` runs a compatibility suite
against a real browser.

### Web worker parsing

Without extra setup, parsing runs on the browser's main thread and a
big book can freeze the UI while it decompresses. Ship the bundled
worker entry point to move it off-thread:

```sh
dart compile js web/e_livre_worker.dart -o <your-web-root>/e_livre_worker.js
```

```dart
import 'package:e_livre/e_livre.dart';

void main() {
  WorkerBookReader.configure(Uri.parse('e_livre_worker.js'));
  runApp(const MyApp());
}
```

`BookReader.openFromBytes` and `readMetadataFromBytes` then run inside
the worker: the main thread only receives the finished book. Parse
failures throw exactly like the inline path; if the worker script is
unreachable or the host blocks workers, parsing silently falls back
to the main thread. CB7 and CBC are intentionally routed through their
asynchronous pure-Dart path rather than the synchronous worker operation.
Native runtimes ignore the configuration because they already use a
background isolate.

## PDF support and boundaries

PDF support is focused on producing stable reading data. `parsePdfBook`
reads classic cross-reference tables, cross-reference streams, object
streams and recoverable broken files. It extracts page text, metadata and
bookmarks, creates one reflow section per page, and keeps the original PDF
bytes for a facsimile reader. The extracted page text is also the canonical
text used by search, progression, locators and both viewer reading modes.

The stream layer handles Flate, LZW, ASCII hex, ASCII85, run-length,
CCITT fax and JBIG2 filters. JPEG XObjects are passed through unchanged;
CCITT and JBIG2 images are decoded to grayscale PNGs. JBIG2 covers
arithmetic and Huffman-coded symbol dictionaries, refinement, pattern and
halftone regions, MMR and shared `/JBIG2Globals` dictionaries. The real
scanned-book Huffman corpus currently compares exactly with pdf.js
v3.11.174: 199 images, 904,063,634 pixels and zero differing pixels.

This is not a general-purpose PDF renderer. Vector graphics, forms,
annotations and image codecs outside the list above are not part of the
extraction contract. When an image filter cannot be decoded, the page can
still retain its placement geometry, but no extracted image bytes are
guaranteed. Encrypted PDFs require a supported standard security handler
and the correct password.

## Known limitations

- CBR supports stored RAR 5 entries and ordinary non-solid RAR 4 method-29
  entries. Encrypted, split, solid, RAR virtual-machine, PPMd and other
  unsupported compressed variants are rejected with `ComicException`.
- CB7 supports readable 7-Zip image entries and common `ComicInfo.xml`
  metadata. Encrypted entries, unsupported codecs or entries above the
  bounded per-entry budget are rejected; CB7/CBC parsing is asynchronous.
- CBC currently flattens the comics listed by `comics.txt` into one
  `ComicBook` page sequence. Collection-level titles are not exposed as a
  separate nested TOC model.
- DOCX and ODT preserve semantic document structure, not pixel-perfect Word
  or LibreOffice layout. Footnotes, charts, equations, advanced numbering,
  fields, tracked-change semantics and complex drawing effects can be lost.
- TXT/TXZ are not full Markdown or Textile engines; advanced extensions are
  kept as text. Plain TXT metadata is inherently limited unless its producer
  includes a recognized header or TXTZ OPF sidecar.
- HTMLZ selects one top-level HTML spine file. Other HTML entries remain
  resources, and arbitrary HTML is preserved rather than sanitized.
- AZW4 requires a valid unencrypted PDF payload inside the PalmDB wrapper;
  DRM-protected wrappers remain unavailable.
- EPUB font obfuscation is limited to the standard IDPF and Adobe algorithms;
  other `encryption.xml` algorithms are treated as DRM and rejected.
- EPUB navigation is optional. A missing or unusable TOC produces an empty
  navigation model when the spine and content remain readable.
- DRM-protected MOBI files are rejected with `DrmProtectedException`.
- Browser code must use byte-based APIs such as `openFromBytes`.
  Path-based APIs and Calibre sidecar lookup are filesystem-only.
- The web worker is opt-in and needs a separately served worker script.
  If it cannot be loaded, parsing falls back to the browser main thread and
  a large book can temporarily block that thread.
- PDF output is reading-oriented rather than a promise of pixel-perfect
  rendering for every producer. Facsimile fidelity depends on the codecs
  and operators supported by the parser.
- The real scanned-book JBIG2 Huffman corpus is pixel-exact, but the small
  synthetic `jbig2_huffman_1` corner-case fixture remains dimension-accurate
  only (about 77-85% pixel agreement). This is not a claim of universal
  JBIG2 raster equivalence.
- Resource and decode budgets intentionally reject malformed or unusually
  large inputs instead of allowing unbounded allocation or work.

## Error handling

- `FormatNotSupportedException` — known but unsupported formats
  (Topaz, KFX, RTF) or unrecognized data.
- `DrmProtectedException` — DRM-protected MOBI files.
- `InvalidBookException` — corrupted files of a detected format.
- `ComicException` — comic archives with no pages or unsupported RAR
  entries.
- `DocxException`, `HtmlException`, `OdtException` and `Comic7Exception` —
  typed errors from the corresponding new format adapters.
- `PdfException` / `PdfEncryptedException` — unreadable or unsupported
  PDF structure and encrypted PDF documents that cannot be opened with
  the supplied password.
- `EpubException` / `MobiException` / `Fb2Exception` — per-format
  parse errors (all extend `ELivreException`).

## Benchmarks

The `benchmark/` suite measures the public API surface — format
detection, full parsing, metadata-only reads, isolate entry points and
the lazy getters (`metadata`, `statistics`, `chapters`, `plainText`) —
against the books in `test/resources`:

```sh
dart run benchmark/e_livre_benchmarks.dart                 # full run
dart run benchmark/e_livre_benchmarks.dart --quick         # fast smoke pass
dart run benchmark/e_livre_benchmarks.dart --filter=parseBook
```

The filter is a case-insensitive substring matched against
`<group> — <benchmark name>`. Results are machine-dependent; compare
runs from the same machine only.

## Example

A complete Flutter reader app lives in [`example/`](example/).

## Compatibility references

The format adapters and regression fixtures record the observable behavior
used from Calibre, Microsoft Open XML guidance and the MIT-licensed
`koni_archive` reader in
[`docs/audits/format-expansion-2026-09-07/`](docs/audits/format-expansion-2026-09-07/).
Calibre is GPLv3; its code was not copied into eLivre.

## License

MIT
