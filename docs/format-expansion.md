# Format expansion: evidence and scope

This release validates KEPUB through the EPUB parser and adds standalone
Markdown, RTF, PalmDOC, eReader PDB, Plucker PDB, CHM, Sony LRF, and a limited
DjVu reader. Fixture origins, hashes, and licenses are recorded in
`test/resources/books/manifest.json` and the relevant `PROVENANCE.md` files.

| Format | Reference and fixture | Implemented reading contract | Remaining boundary |
| --- | --- | --- | --- |
| KEPUB | [Kepubify](https://github.com/pgaskin/kepubify) derivative of a [W3C EPUB sample](https://github.com/IDPF/epub3-samples) | Opens as EPUB, retaining Kobo spans and EPUB metadata | A Kobo-specific format type cannot be inferred reliably from ZIP bytes; independent Kobo-produced fixture remains desirable. |
| Markdown | [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) and [Dart Markdown](https://pub.dev/packages/markdown); original fixture and Chrome test | Standalone files, HTML, heading navigation, simple front matter | Relative resources are not loaded; raw HTML needs consumer-side isolation. |
| RTF | [Microsoft RTF 1.9.1](https://officeprotocoldoc.z19.web.core.windows.net/files/Archive_References/%5BMSFT-RTF%5D.pdf); original fixture and Calibre's `LICENSE.rtf` | Text, title/author, Unicode, codepages, paragraphs, basic emphasis | Tables, pictures, drawing objects and page layout are not converted. |
| PalmDOC PDB | [Calibre PalmDOC header](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/palmdoc.txt) and [compression notes](https://github.com/kovidgoyal/calibre/blob/master/format_docs/compression/palmdoc.txt); generated file | Plain text with raw or PalmDOC-compressed `TEXt/REAd` records | Other PalmDB identities use their own parsers. |
| eReader PDB | [Calibre format notes](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/ereader.txt); Calibre 9.4.0-generated original content and Chrome test | Unencrypted `PNRd/PPrs` text, title and author | PML resources, footnotes, sidebars, links and page layout are flattened or omitted. |
| Plucker PDB | [Official Plucker format](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/plucker.html); [PyPlucker 3.7](https://github.com/lxmx/PyPlucker) DOC and zlib files from original HTML | Text paragraphs, continued records, and database title | Images, link targets, bookmarks, owner-keyed content and rich layout are not converted; independently produced real-world fixture remains desirable. |
| CHM | [CHM format notes](https://www.nongnu.org/chmspec/latest/), [jchmlib](https://github.com/chimenchen/jchmlib), Microsoft's [E8 translation rules](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-patch/e6c8366d-a8c3-4f34-aa5d-56f44f938a09), and [Windows code page identifiers](https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers); licensed PuTTY manual plus generated CP1251/1252/1256 CHM samples | LZX-compressed HTML topics, CSS, metadata, hierarchical contents, Intel E8 restoration, and locale-selected Windows-1251/1252/1256 decoding | Other codepages, full-text index, merged help, and script execution remain outside the contract. |
| Sony LRF | [Calibre reader](https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/lrf); Calibre 9.4.0-generated text and image fixtures; synthetic legacy-header variants | Ordered reflowed text pages and metadata for versions 1–800 and 801+, table of contents and inline images | Precise Sony layout, ruby styling, complex canvases, and an independently produced redistributable fixture remain. |
| Sony LRX | Sony's [Reader format list](https://www.sony.com/electronics/support/articles/S1F0504) separates unsecured BBeB from Marlin-protected BBeB; its [BBeB release](https://www.sony.com/ja/SonyInfo/News/Press/200403/04-0324A/) describes OpenMG rights protection. Calibre is only a behavioral oracle for `ftypLRX2` and the nested `bbeb` metadata layout. | Reads plaintext metadata found in that nested LRF stream; full LRX book parsing fails with a DRM-typed error. | Sony does not publish the LRX wrapper layout in these references. No protected payload is inspected or decrypted. Legacy LRX metadata and independently licensed LRX samples remain unsupported. |
| DjVu direct JPEG | [DjVu 3 specification](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf) and [DjVuLibre](https://github.com/DjVuLibre/DjVuLibre); generated JPEG page plus two real licensed unsupported-codec fixtures | Visual pages when each page has directly stored `BGjp` JPEG, dimensions, optional uncompressed OCR | Common JB2/IW44 page layers, compressed text/bookmarks, and indirect files are rejected with typed failures. This is not broad DjVu visual support. |

The parser implementations are pure Dart. Reference tools and implementations
were used for format behavior and fixtures; their GPL source code is not
copied into the package. Every parser has focused valid and malformed-input
tests. Browser tests exercise the new format paths that depend on web
decoding or wire transport.

## Validation still needed

- Add independently produced, redistributable LRF, Plucker, and Kobo KEPUB
  files to broaden compatibility evidence. The Yosemite *Steep Trails* LRF was
  found, but its downloadable binary could not be accessed through the browser
  and the page does not state a license for the LRF packaging, so it is not
  used.
- Implement JB2 and IW44 image layers before describing DjVu as a general
  scanned-book reader. Preserve the current typed failure for these layers.
- Add redistributable samples for CHM codepages beyond Windows-1251/1252/1256.
- Add eReader PML resources and Plucker images/navigation only with licensed
  fixtures that exercise the corresponding record structures.
