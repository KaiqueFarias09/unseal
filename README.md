# eLivre

Pure Dart book parsing library. Extract metadata, covers, content,
stylesheets, fonts and navigation from **EPUB 2.0/3.0**, **MOBI**,
**AZW3 (KF8)**, **FB2** and **comic archives (CBZ/CBR)** — no native
dependencies, one API.

## Features

- Format detection by magic bytes (`epub`, `mobi`, `azw3`, `fb2`,
  `cbz`, `cbr`).
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
  stay responsive); falls back to synchronous parsing on the web.

## Getting started

```yaml
dependencies:
  e_livre: ^3.1.0
```

## Usage

Open any supported book and work with it generically:

```dart
import 'package:e_livre/e_livre.dart';

final book = await EBook.openFromPath('/books/wonderland.azw3');

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
final metadata = await EBook.readMetadataFromPath(path);
print(metadata.title);
print(metadata.cover?.mimeType); // image/jpeg
```

Format-specific entry points are still available:

```dart
final epub = await EpubBook.fromFile(file);   // EPUB only
final mobi = parseMobiBook(bytes);            // MOBI / AZW3
final fb2 = parseFb2Book(bytes);              // FB2 / FB2.zip
final comic = parseComicBook(bytes);          // CBZ / CBR
```

## Error handling

- `FormatNotSupportedException` — known but unsupported formats
  (Topaz, KFX, PDF, RTF) or unrecognized data.
- `DrmProtectedException` — DRM-protected MOBI files.
- `InvalidBookException` — corrupted files of a detected format.
- `ComicException` — comic archives with no pages or with compressed
  RAR entries.
- `EpubException` / `MobiException` / `Fb2Exception` — per-format
  parse errors (all extend `ELivreException`).

## Example

A complete Flutter reader app lives in [`example/`](example/).

## License

MIT
