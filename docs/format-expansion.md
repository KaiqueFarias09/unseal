# Format expansion: evidence and scope

This branch adds RTF, standalone Markdown, and PalmDOC PDB parsing. It also
validates that a Kepubify-generated KEPUB opens through the existing EPUB
parser. The new fixtures and their hashes are recorded in
`test/resources/books/format_expansion/PROVENANCE.md`.

| Format | Parsing reference | Test evidence | Scope in this branch |
| --- | --- | --- | --- |
| RTF | [Microsoft RTF 1.9.1](https://officeprotocoldoc.z19.web.core.windows.net/files/Archive_References/%5BMSFT-RTF%5D.pdf) | Hand-authored control-word fixture and Calibre's real `LICENSE.rtf` | Text, title, author, Unicode, codepages, paragraphs, and basic character emphasis. Non-reading groups and embedded binary data are skipped. |
| Markdown | [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) and the [Dart Markdown parser](https://pub.dev/packages/markdown) | Hand-authored front matter and document fixture, plus browser test | Standalone files and explicit byte API, generated HTML, nested heading navigation, and simple metadata. |
| PalmDOC PDB | [Calibre PalmDOC header](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/palmdoc.txt) and [compression format](https://github.com/kovidgoyal/calibre/blob/master/format_docs/compression/palmdoc.txt) | Generated `TEXt/REAd` file plus tests for raw records, byte pairs, back references, and corrupt data | Plain text PalmDOC with compression 1 or 2. Other PDB ebook families have different record contracts. |
| KEPUB | [Kepubify](https://github.com/pgaskin/kepubify) | Kepubify-generated derivative of a [W3C EPUB sample](https://github.com/IDPF/epub3-samples) | Opens as EPUB, retaining Kobo spans and EPUB metadata. There is no separate byte-level KEPUB identity. |

CHM, DjVu, and LRF remain outside this branch. There are [CHM container
notes](https://www.nongnu.org/chmspec/latest/), a [CHMLib reference
implementation](https://github.com/jedwing/CHMLib), and an [MIT-licensed PuTTY
CHM fixture](https://github.com/bjxpen/chmv). A useful CHM reader would still
need a portable, bounded LZX decoder and tests for compressed directory,
navigation, and resource variants; the current archive dependency does not
provide that decoder.

[DjVuLibre](https://github.com/DjVuLibre/DjVuLibre) provides a reference
implementation and [DjVu 3 specification](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf).
Reading scanned DjVu publications requires image codec work beyond extracting
an optional text chunk. A text-only result would not satisfy the book-reading
contract already offered for PDF and comics.

Calibre has an [LRF reader](https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/lrf),
but this review did not establish an independently usable format specification
and a redistributable real-world fixture set covering text and images. Support
should be claimed only after both are available.

These decisions are about testable reader output and the project's pure-Dart
boundary. They do not assert that the formats are unimportant or that their
implementations would be too expensive.
