# eLivre

Pure Dart book parsing library. Extract metadata, covers, content,
stylesheets, fonts and navigation from **EPUB 2.0/3.0**, **MOBI**,
**AZW3 (KF8)**, **FB2**, **comic archives (CBZ/CBR)** and **PDF** —
no native dependencies, one API.

## Features

- Format detection by magic bytes (`epub`, `mobi`, `azw3`, `fb2`,
  `cbz`, `cbr`, `pdf`).
- Metadata-only fast path: title, authors, languages, publisher,
  ISBN, subjects, dates, identifiers, series and cover without
  extracting the book content.
- **Calibre integration**: a sibling `<basename>.opf` / `metadata.opf`
  sidecar merges over the book's own metadata, and books without any
  metadata fall back to the `Title - Author.ext` filename pattern.
- Full parse with parity across formats: HTML content files, CSS,
  images, fonts and the table of contents.
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
- Comics: CBZ (with `ComicInfo.xml` metadata) and CBR (RAR 4/5 with
  stored entries), pages in natural order, first page as cover.
- Parsing runs in a background isolate when available (Flutter apps
  stay responsive); on the web an opt-in web worker does the same,
  with inline parsing as the fallback.

## Getting started

```yaml
dependencies:
  e_livre: ^3.1.0
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
final epub = await BookReader.openFromPath(file.path);   // EPUB only
final mobi = parseMobiBook(bytes);            // MOBI / AZW3
final fb2 = parseFb2Book(bytes);              // FB2 / FB2.zip
final comic = parseComicBook(bytes);          // CBZ / CBR
final pdf = parsePdfBook(bytes);               // PDF
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
to the main thread. Native runtimes ignore the configuration — they
already use a background isolate.

## Error handling

- `FormatNotSupportedException` — known but unsupported formats
  (Topaz, KFX, RTF) or unrecognized data.
- `DrmProtectedException` — DRM-protected MOBI files.
- `InvalidBookException` — corrupted files of a detected format.
- `ComicException` — comic archives with no pages or with compressed
  RAR entries.
- `PdfException` / `PdfEncryptedException` — unreadable PDF structure
  and encrypted PDF documents (the one PDF class this library rejects
  outright).
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

## License

MIT
