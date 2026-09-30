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
| Plucker PDB | [Official Plucker format](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/plucker.html); [Palm OS SDK bitmap structures](https://www.fuw.edu.pl/~michalj/palmos/Bitmap.html); [Palm OS Programmer's Companion](https://palm.wiki/development/docs/601/PalmOSCompanion/UserInterface.html); [PyPlucker 3.7](https://github.com/lxmx/PyPlucker) DOC and zlib files from original HTML; generated Palm bitmap records | Text paragraphs, continued records, paragraph links, title, 1/2/4-bit grayscale images, 8-bit system and custom palettes, and 16-bit RGB565 direct-color bitmaps | Custom palettes and RGB565 are tested with generated Palm-bitmap fixtures; no real Plucker book containing either variant has been verified. The Plucker 1.1 builder documents only 1/2/4/8-bit image output. Internally compressed bitmaps, bookmarks, owner-keyed content, and rich layout remain unsupported. |
| CHM | [CHM format notes](https://www.nongnu.org/chmspec/latest/), [jchmlib](https://github.com/chimenchen/jchmlib), Microsoft's [E8 translation rules](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-patch/e6c8366d-a8c3-4f34-aa5d-56f44f938a09), and [Windows code page identifiers](https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers); licensed PuTTY manual plus generated CP1251/1252/1256 CHM samples | LZX-compressed HTML topics, CSS, metadata, hierarchical contents, Intel E8 restoration tested with generated frames, and locale-selected Windows-1251/1252/1256 decoding | Other codepages, full-text index, merged help, script execution, and a real CHM that enables E8 remain outside the evidence. The PuTTY fixture has E8 disabled. |
| Sony LRF | [Calibre reader](https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/lrf); Calibre 9.4.0-generated text and image fixtures; synthetic legacy-header variants. Eruditio's independent writer at `c517504` was evaluated but its output is rejected by both readers because its BookAttr uses an unrecognized generic Link tag. | Ordered reflowed text pages and metadata for versions 1–800 and 801+, table of contents and inline images | Precise Sony layout, ruby styling, complex canvases, and a valid independently produced or device-origin fixture remain. The Eruditio output is excluded; see `test/resources/books/lrf/PROVENANCE.md`. |
| Sony LRX | Sony's [Reader format list](https://www.sony.com/electronics/support/articles/S1F0504) separates unsecured BBeB from Marlin-protected BBeB; its [BBeB release](https://www.sony.com/ja/SonyInfo/News/Press/200403/04-0324A/) describes OpenMG rights protection. Calibre is only a behavioral oracle for `ftypLRX2` and the nested `bbeb` metadata layout. | Reads plaintext metadata found in that nested LRF stream; full LRX book parsing fails with a DRM-typed error. | Sony does not publish the LRX wrapper layout in these references. No protected payload is inspected or decrypted. Legacy LRX metadata and independently licensed LRX samples remain unsupported. |
| DjVu JPEG, JB2, and IW44 | [DjVu 3 specification](https://www.sndjvu.org/spec.html); ZP and IW44 behavior cross-check against the independent [MIT-licensed djvu-rs implementation](https://github.com/matyushkin/djvu-rs); public-domain Sjbz and Unlicense BG44/FG44 photo and compound fixtures | Direct `BGjp`, page-local `Sjbz`, progressive IW44 v1.0-v1.2 `BG44`/`FG44`, and `Sjbz`-mask composition in single-page or bundled documents produce displayable images. Supports JB2 direct symbols, matched refinements, local copies, IW44 zero-slice chunks and chroma delay, dimensions, rotation, and uncompressed OCR. VM tests compare real grayscale and color photo/compound pages with upstream PNG references; Chrome tests verify grayscale display and wire preservation. | Shared `Djbz`/`INCL` symbols, alternate visual codecs, compressed `TXTz`/`NAVM`, reset records, and indirect documents remain unsupported. A document is capped at 256 million decoded pixels and 128 MiB of materialized raster bytes; IW44 adds chunk/slice/coefficient-work caps. A 62 MP source is rejected before plane allocation when its full-resolution work exceeds the byte budget. |
| TIFF and BigTIFF | [TIFF 6.0 specification](https://download.osgeo.org/libtiff/doc/TIFF6.pdf) and libtiff 4.7.2 as the behavioral reference; libtiff's own MIT-licensed test images (real Group 4 fax, EOL-less Group 3, old-style compat LZW, multi-IFD and SubIFD chains, hostile IFD loops) plus deterministic fixtures transcoded with `tiffcp` | Multi-page IFD chains in both byte orders and BigTIFF 64-bit offsets produce BMP page images. Codecs: uncompressed, PackBits, LZW (standard and bit-reversed compat, late width change), Deflate/AdobeDeflate with horizontal-differencing predictors, CCITT Group 4 and Group 3 (modified Huffman included, EOL-less producers retried) through a strict row-oriented T.4/T.6 decoder; JPEG passthrough for self-contained strips. Every decodable fixture is verified page-by-page with `tiffcmp -t` against a `tiffcp -c none` reference; the real bilevel and gray images are additionally checked against libtiff's PBM/PGM pixel oracles, and raster SHA-256 goldens pin the bytes. | Typed `TiffUnsupportedCodecException` for tiled raster, planar=2, palette, float samples, LogLuv, JPEGTables-abbreviated strips, old-style JPEG, reversed FillOrder, and uncompressed-mode extensions; `TiffException` before any declared allocation for hostile offsets, counts, cycles, and truncation. Limits: 128 MiB input, 1,024 pages, 65,536 IFD entries, 4 samples/pixel, 256 MP/page, 1M segments/page, 128 MiB decoded raster. |

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
- Broaden IW44 real-file coverage beyond the current Unlicense photo and
  compound assets; the checked references cover selected real producers and
  do not claim complete DjVu v3 conformance.
- Compressed `TXTz`, `NAVM`, shared `Djbz` dictionaries with `INCL`, and
  indirect component resolution are implemented and verified against the
  scanned-archive corpus (byte-exact `djvutxt` text parity, `ddjvu` pixel
  parity for mask and photo pages, and the derived indirect fixture); the
  composed-MRC rendering keeps the house hard-selection convention with a
  bounded, pinned deviation from ddjvu's blended stencil. Still open inside
  DjVu: `FGjp`/`Smmr` layer replacements, `ANTz` annotation parsing, chained
  shared dictionaries, and `BMKz` (no corpus fixture exists).
- Add redistributable samples for CHM codepages beyond Windows-1251/1252/1256
  and find or generate a licensed real CHM whose LZX stream enables Intel E8.
  The current PuTTY fixture has the E8 flag clear; the Free Pascal
  `paslzxcomp` compressor also writes the flag as zero. Current E8 tests use
  synthetic frames only; details and source links are in
  `test/resources/books/chm/PROVENANCE.md`.
- Broaden the TIFF corpus with a redistributable real multi-page scanned
  document (the Library of Congress free-to-use sets sit behind a Cloudflare
  challenge that blocked scripted acquisition on 2026-09-30; the libtiff test
  corpus was substituted). The historical Group 4 file `testfax4.tiff` decodes
  pixel-identically through the new row-oriented decoder; its row-235
  reference-state sequencing differs from pdf.js's port and is covered by the
  libtiff-parity goldens rather than the pdf.js-derived core.
- Add redistributable samples for CHM codepages beyond Windows-1251/1252/1256
  and find or generate a licensed real CHM whose LZX stream enables Intel E8.
  The current PuTTY fixture has the E8 flag clear; the Free Pascal
  `paslzxcomp` compressor also writes the flag as zero. Current E8 tests use
  synthetic frames only; details and source links are in
  `test/resources/books/chm/PROVENANCE.md`.
- Broaden eReader PML and Plucker record coverage beyond the implemented
  images, local links, and navigation, using licensed fixtures.
