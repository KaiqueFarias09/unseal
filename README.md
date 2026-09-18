# eLivre

eLivre is a pure-Dart book parser and reading-data library. Give it bytes or a
filesystem path and receive one format-neutral `Book` model with metadata,
cover data, files, reading order, navigation, and statistics.

It supports EPUB, MOBI, AZW3, FB2, TXT, HTML, DOCX, ODT, AZW4, comic
archives, and PDF without a native executable, FFI bridge, or Flutter
dependency in the library itself.

eLivre is a parser and data layer, not a reader UI or a general-purpose
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
| EPUB 2/3 | OPF metadata, spine, XHTML, CSS, images, fonts, media overlays, navigation, and CFI | Font obfuscation is limited to the standard IDPF and Adobe algorithms. |
| MOBI 6 | PalmDOC and HUFF/CDIC decompression, EXTH metadata, chapters, images, fonts, and navigation | DRM-protected books are rejected. |
| AZW3 / KF8 | Skeleton and `div` reassembly, FDST flows, CSS/SVG, images, NCX navigation, and joint MOBI/KF8 files | DRM-protected books are rejected. |
| FB2 / FBZ | Metadata, covers, declared encodings, notes, links, styles, and section navigation | The result is a reflowable HTML representation. |
| TXT / TXTZ | UTF-8/UTF-16 decoding, paragraph-preserving XHTML, archive resources, and basic Markdown/Textile | Not a full Markdown or Textile implementation. Plain TXT metadata is limited. |
| HTML / HTMLZ | Source-preserving HTML, head metadata, heading navigation, OPF manifests, and resources | HTML is preserved, not sanitized. |
| DOCX | Open XML document structure, styles, headings, lists, tables, links, properties, and images | Semantic conversion; not pixel-perfect Word layout. |
| ODT | OpenDocument paragraphs, headings, styles, lists, tables, images, links, and metadata | Semantic conversion; not pixel-perfect LibreOffice layout. |
| AZW4 | PalmDB/MOBI wrapper validation, PDF extraction, metadata, pages, and original PDF bytes | Requires a valid, unencrypted PDF payload. |
| CBZ | ZIP comic pages, `ComicInfo.xml`, natural ordering, and first-page cover | Page-oriented data; no comic UI is included. |
| CBR | RAR 4 stored and ordinary non-solid method-29 entries, plus RAR 5 stored entries | Split, solid, encrypted, PPMd, VM, and other unsupported variants are rejected. |
| CB7 | 7-Zip comic pages, `ComicInfo.xml`, natural ordering, and first-page cover | Asynchronous only; encrypted or unsupported entries are rejected. |
| CBC | Top-level `comics.txt` collections containing CBZ, CBR, or CB7 files | The collection is flattened into one `ComicBook` page sequence. |
| PDF | Metadata, bookmarks, page text, reflow HTML, facsimile data, and JPEG/CCITT/JBIG2 images | Reading-oriented extraction, not a general-purpose PDF renderer. |

`OPF` is not a standalone reading format. When eLivre finds `metadata.opf`
inside TXTZ or HTMLZ, or a sibling `<book-name>.opf` beside a native file, it
uses it as a metadata and manifest sidecar.

## Installation

```sh
dart pub add e_livre
```

Or add the dependency manually:

```yaml
dependencies:
  e_livre: ^3.0.0
```

The package requires Dart `>=3.8.0 <4.0.0`.

## Quick start

The byte-based asynchronous API is the most portable entry point:

```dart
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';

Future<Book> openBook(Uint8List bytes) {
  return BookReader.openFromBytes(bytes);
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
final metadata = await BookReader.readMetadataFromBytes(bytes);
print(metadata.title);
print(metadata.authors);
```

On native platforms, filesystem paths are also supported:

```dart
final book = await BookReader.openFromPath('/books/wonderland.epub');
final metadata = await BookReader.readMetadataFromPath('/books/wonderland.epub');
```

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

CB7 and CBC use an asynchronous 7-Zip reader. `parseBook` and
`readMetadataSync` reject those formats; use `openFromBytes`,
`readMetadataFromBytes`, or the dedicated asynchronous functions instead.

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
| Browser JavaScript with worker | Bytes only | `WorkerBookReader` can move normal parsing off the main thread. |
| WebAssembly | Not currently claimed as a verified target | There is no WASM build or compatibility guarantee in the current validation matrix. |

### Browser usage

Browser applications should fetch or otherwise obtain a `Uint8List` and use a
byte-based API. `openFromPath` and `readMetadataFromPath` throw
`UnsupportedError` on the web.

To keep large parses off the browser's main thread, compile and serve the
worker entry point:

```sh
dart compile js web/e_livre_worker.dart -o <your-web-root>/e_livre_worker.js
```

Configure it before opening books:

```dart
import 'package:e_livre/e_livre.dart';

void configureReader() {
  WorkerBookReader.configure(Uri.parse('e_livre_worker.js'));
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

eLivre produces reading data; it does not render pages or provide navigation
controls. DOCX and ODT preserve semantic structure and common formatting, but
complex layouts, footnotes, charts, equations, advanced numbering, fields,
tracked changes, and complex drawing effects can be lost.

PDF support is designed for reading modes and extraction. It is not a promise
of pixel-perfect rendering for every PDF producer. Vector graphics, forms,
annotations, and image codecs outside the supported extraction contract may be
omitted. The original PDF bytes are retained for an application that provides
its own facsimile renderer.

### Input and archive boundaries

- Every ZIP-backed format goes through the same bounded decoder. Before
  inflation, eLivre rejects containers declaring more than 1 GiB in total,
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
- TXT/TXZ conversion covers basic Markdown/Textile constructs, not every
  extension of either format.
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
standard-security documents can be opened with the correct password, but PDF
permission flags are exposed as metadata and are not enforced by eLivre.

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

- Observable metadata and conversion conventions from Calibre. Calibre is a
  compatibility reference, not a runtime dependency, and Calibre source is
  not copied into eLivre.
- Microsoft Open XML guidance for DOCX package structure.
- `koni_archive` for the pure-Dart 7-Zip implementation used by CB7 and CBC.
- PDF.js and Poppler as independent references for PDF extraction and image
  behavior.

Detailed fixture provenance and comparison notes live in
[`docs/audits/format-expansion-2026-09-07/`](docs/audits/format-expansion-2026-09-07/).

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
dart run benchmark/e_livre_benchmarks.dart --quick
dart run benchmark/e_livre_benchmarks.dart
dart run benchmark/e_livre_benchmarks.dart --json=artifacts/current.json
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
