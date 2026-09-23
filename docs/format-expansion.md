# Format expansion: evidence and scope

This release validates KEPUB through the EPUB parser and adds standalone
Markdown, RTF, PalmDOC, eReader PDB, Plucker PDB, CHM, Sony LRF, and a limited
DjVu reader. Fixture origins, hashes, and licenses are recorded in
`test/resources/books/manifest.json` and the relevant `PROVENANCE.md` files.

| Format | Reference and fixture | Implemented reading contract | Remaining boundary |
| --- | --- | --- | --- |
| KEPUB | A [Kepubify](https://github.com/pgaskin/kepubify) conversion of a [W3C EPUB sample](https://github.com/IDPF/epub3-samples), plus a [Standard Ebooks Kobo edition](https://standardebooks.org/ebooks/stephen-crane/the-red-badge-of-courage) produced independently | Both open through the EPUB parser with Kobo spans, navigation, images, and EPUB metadata | ZIP bytes alone do not reliably identify KEPUB; the public model reports `BookFormat.epub`. A file produced by Kobo itself has not been tested. |
| Markdown | [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) and [Dart Markdown](https://pub.dev/packages/markdown); original fixture and Chrome test | Standalone files, HTML, heading navigation, simple front matter | Relative resources are not loaded; raw HTML needs consumer-side isolation. |
| RTF | [Microsoft RTF 1.9.1](https://officeprotocoldoc.z19.web.core.windows.net/files/Archive_References/%5BMSFT-RTF%5D.pdf); original fixture and Calibre's `LICENSE.rtf` | Text, title/author, Unicode, codepages, paragraphs, basic emphasis | Tables, pictures, drawing objects and page layout are not converted. |
| PalmDOC PDB | [Calibre PalmDOC header](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/palmdoc.txt) and [compression notes](https://github.com/kovidgoyal/calibre/blob/master/format_docs/compression/palmdoc.txt); generated file | Plain text with raw or PalmDOC-compressed `TEXt/REAd` records | Other PalmDB identities use their own parsers. |
| eReader PDB | [Calibre format notes](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/ereader.txt); Calibre 9.4.0-generated original content and Chrome test | Unencrypted `PNRd/PPrs` text, title, author, PML headings/emphasis/local links, PNG resources, footnotes and sidebars | Reading-oriented HTML omits some PML controls and exact page layout; footnote record coverage is synthetic. |
| Plucker PDB | [Official Plucker format](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/plucker.html); [PyPlucker 3.7](https://github.com/lxmx/PyPlucker) DOC and zlib files from original HTML; a generated Palm bitmap record fixture | Text paragraphs, continued records, paragraph links, title, 1/2/4-bit grayscale images, and uncompressed 8-bit system-palette images | Custom color tables, internally compressed and 16-bit direct-color images, bookmarks, owner-keyed content, and rich layout remain unsupported; independently produced real-world image fixture remains desirable. |
| CHM | [CHM format notes](https://www.nongnu.org/chmspec/latest/), [jchmlib](https://github.com/chimenchen/jchmlib), Microsoft's [E8 translation rules](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-patch/e6c8366d-a8c3-4f34-aa5d-56f44f938a09), and [Windows code page identifiers](https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers); licensed PuTTY manual plus generated CP1251/1252/1256 CHM samples | LZX-compressed HTML topics, CSS, metadata, hierarchical contents, Intel E8 restoration, and locale-selected Windows-1251/1252/1256 decoding | Other codepages, full-text index, merged help, and script execution remain outside the contract. |
| Sony LRF | [Calibre reader](https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/lrf); Calibre 9.4.0-generated text and image fixtures; synthetic legacy-header variants. Eruditio's independent writer at `c517504` was evaluated but its output is rejected by both readers because its BookAttr uses an unrecognized generic Link tag. | Ordered reflowed text pages and metadata for versions 1–800 and 801+, table of contents and inline images | Precise Sony layout, ruby styling, complex canvases, and a valid independently produced or device-origin fixture remain. The Eruditio output is excluded; see `test/resources/books/lrf/PROVENANCE.md`. |
| Sony LRX | Sony's [Reader format list](https://www.sony.com/electronics/support/articles/S1F0504) separates unsecured BBeB from Marlin-protected BBeB; its [BBeB release](https://www.sony.com/ja/SonyInfo/News/Press/200403/04-0324A/) describes OpenMG rights protection. Calibre is only a behavioral oracle for `ftypLRX2` and the nested `bbeb` metadata layout. | Reads plaintext metadata found in that nested LRF stream; full LRX book parsing fails with a DRM-typed error. | Sony does not publish the LRX wrapper layout in these references. No protected payload is inspected or decrypted. Legacy LRX metadata and independently licensed LRX samples remain unsupported. |
| DjVu JPEG and bounded JB2 | [DjVu 3 specification](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf); JB2/ZP state-table cross-check against the independent [MIT-licensed djvu-rs implementation](https://github.com/matyushkin/djvu-rs); generated JPEG page and a real public-domain US State Department Sjbz layer, plus a real Unlicense IW44 rejection fixture | Direct `BGjp` pages and page-local `Sjbz` in single-page or bundled documents decode to black-on-white 1-bit BMP. Supports direct symbols, matched refinements, local copies, dimensions, rotation, and uncompressed OCR. VM and Chrome tests check a real 2550 × 3301 JB2 layer and wire preservation. | IW44 `BG44`/`FG44`, composed pages with multiple visual layers, `Djbz`/`INCL` shared symbols, reset records, alternate masks, compressed `TXTz`/`NAVM`, and indirect documents remain unsupported. A document is capped at 256 million decoded pixels and 128 MiB of materialized raster output. Real source pages that contain co-located IW44 layers still fail full opening. |

The parser implementations are pure Dart. The JB2 ZP state-table constants
were cross-checked against djvu-rs; its MIT license is included in
`licenses/djvu-rs-MIT.txt`. DjVuLibre was consulted only for general format
context; none of its GPL source is copied. Every parser has focused valid and
malformed-input tests. Browser tests exercise the new format paths that depend
on web decoding or wire transport.

## Validation still needed

- Add an independently produced, redistributable LRF file to broaden
  compatibility evidence. The pinned Eruditio writer output is rejected by
  Unseal and Calibre 9.4.0; its output hash and the tag mismatch are recorded
  in `test/resources/books/lrf/PROVENANCE.md`. Eruditio's pinned real-world
  test data has no LRF. The Yosemite *Steep Trails* LRF candidate does not
  state a license for the LRF packaging, so it is not used. The KEPUB corpus
  already includes an independent Standard Ebooks Kobo edition.
- Add IW44 color decoding and compound-layer composition. JB2 currently emits
  only a bilevel mask; it does not render the background or foreground layers.
- Add shared `Djbz` dictionaries, `INCL` resolution, reset records, compressed
  `TXTz`/`NAVM`, and indirect component resolution before broadening the DjVu
  contract.
- Add redistributable samples for CHM codepages beyond Windows-1251/1252/1256
  and a real CHM that exercises Intel E8 translation.
- Broaden eReader PML and Plucker record coverage beyond the implemented
  images, local links, and navigation, using licensed fixtures.
