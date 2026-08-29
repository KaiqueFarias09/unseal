# eLivre

Pure Dart book parsing library. Extract metadata, covers, content,
stylesheets, fonts and navigation from **EPUB 2.0/3.0**, **MOBI**,
**AZW3 (KF8)** and **FB2** ebooks — no native dependencies, one API.

## Features

- Format detection by magic bytes (`epub`, `mobi`, `azw3`, `fb2`).
- Metadata-only fast path: title, authors, languages, publisher,
  ISBN, subjects, dates, identifiers and cover without extracting
  the book content.
- Full parse with parity across formats: HTML content files, CSS,
  images, fonts and the table of contents.
- MOBI internals implemented from scratch: PalmDoc and HUFF/CDIC
  decompression, EXTH metadata, KF8 skeleton/div reassembly, FDST
  flows, CONT/CRES image containers and NCX navigation, including
  joint MOBI 6 + KF8 files.
- FB2 body-to-XHTML conversion with notes bodies and section-based
  navigation; zipped FB2 (`.fbz`) supported.
- Parsing runs in a background isolate when available (Flutter apps
  stay responsive); falls back to synchronous parsing on the web.

## Getting started

```yaml
dependencies:
  e_livre: ^3.0.0
```

## Usage

Open any supported book and work with it generically:

```dart
import 'package:e_livre/e_livre.dart';

final book = await EBook.openFromPath('/books/wonderland.azw3');

print(book.format.name);            // azw3
print(book.metadata.title);         // Alice's Adventures in Wonderland
print(book.metadata.authors);       // [Lewis Carroll]
print(book.metadata.cover?.bytes);  // cover image bytes

print(book.navigation.navPoints);   // table of contents
print(book.files.html);             // content files
print(book.files.css);              // stylesheets
print(book.files.fonts);            // fonts
print(book.files.images);           // images
```

Or switch on the concrete type for format-specific access:

```dart
switch (book) {
  case EpubBook epub:
    print(epub.version);        // 3.0
    print(epub.package);        // parsed OPF package
  case MobiBook mobi:
    print(mobi.version);        // 6 or 8
  case Fb2Book fb2:
    print(fb2.files.html.first.content);
}
```

Only need metadata (e.g. for a library scanner)? Skip the content
extraction entirely:

```dart
final metadata = await EBook.readMetadataFromBytes(bytes);
print(metadata.title);
print(metadata.cover?.mimeType); // image/jpeg
```

Format-specific entry points are still available:

```dart
final epub = await EpubBook.fromFile(file);   // EPUB only
final mobi = parseMobiBook(bytes);            // MOBI / AZW3
final fb2 = parseFb2Book(bytes);              // FB2 / FB2.zip
```

## Error handling

- `FormatNotSupportedException` — known but unsupported formats
  (Topaz, KFX, PDF, RTF) or unrecognized data.
- `DrmProtectedException` — DRM-protected MOBI files.
- `InvalidBookException` — corrupted files of a detected format.
- `EpubException` / `MobiException` / `Fb2Exception` — per-format
  parse errors (all extend `ELivreException`).

## Example

A complete Flutter reader app lives in [`example/`](example/).

## License

MIT
