# Format expansion audit — 2026-09-07

This note records the compatibility decisions behind the TXT/TXZ, HTML/HTMLZ,
DOCX, AZW4, CB7/CBC and ODT adapters. Calibre was used as a behavioral
reference only. No Calibre source was copied into eLivre; eLivre remains MIT
licensed and the implementation is independent pure Dart.

## Behavioral references

- [Calibre TXT input](https://raw.githubusercontent.com/kovidgoyal/calibre/master/src/calibre/ebooks/conversion/plugins/txt_input.py)
  accepts TXT and TXTZ and treats an optional `metadata.opf` as package
  metadata. The adapter also preserves Calibre's useful TXTZ conventions:
  multiple text members, deterministic source order and formatting hints.
- [Calibre HTMLZ input](https://raw.githubusercontent.com/kovidgoyal/calibre/master/src/calibre/ebooks/conversion/plugins/htmlz_input.py)
  selects a top-level index document and an optional OPF sidecar. eLivre keeps
  OPF in the metadata/manifest channel instead of exposing it as a reading
  document.
- [Calibre DOCX input](https://raw.githubusercontent.com/kovidgoyal/calibre/master/src/calibre/ebooks/conversion/plugins/docx_input.py)
  delegates the Open XML package to a DOCX-to-HTML conversion path. eLivre
  implements the interoperable subset directly: WordprocessingML paragraphs,
  headings, lists, tables, runs, hyperlinks, relationships and images.
- [Microsoft Open XML package guidance](https://learn.microsoft.com/en-us/office/open-xml/general/how-to-create-a-package)
  defines the ZIP parts and relationship model used by the DOCX adapter.
- [Calibre AZW4 input](https://raw.githubusercontent.com/kovidgoyal/calibre/master/src/calibre/ebooks/conversion/plugins/azw4_input.py)
  identifies AZW4 as a PDF-backed wrapper. eLivre validates the PalmDB/MOBI
  envelope, rejects DRM, extracts the PDF records and reuses the existing PDF
  parser.
- [Calibre comic input](https://raw.githubusercontent.com/kovidgoyal/calibre/master/src/calibre/ebooks/conversion/plugins/comic_input.py)
  defines CB7/CBC support and the CBC `comics.txt` collection convention.
- [koni_archive](https://github.com/zenbaku/koni_archive) is the MIT-licensed
  pure-Dart archive layer used for 7-Zip reading. It supports the VM, Flutter
  native and web targets without shelling out to a platform executable.

Calibre itself is [GPLv3](https://github.com/kovidgoyal/calibre), so the
references above guide observable behavior and fixture design; they are not a
source-code dependency of this package.

## Implemented contract

| Family | eLivre result | Deliberate boundary |
| --- | --- | --- |
| TXT | `DocumentBook` with escaped XHTML, UTF-8/UTF-16 decoding, metadata-only reads and safe size limits | Plain text does not carry reliable metadata; a small header convention is recognized when present |
| TXTZ | Multiple text sections, natural order, Markdown/Textile basics, CSS/images/fonts/other resources, OPF metadata and cover hints | It is not a full Markdown/Textile engine |
| HTML | Source-preserving HTML/XHTML, head metadata and heading navigation | The library does not sanitize or rewrite arbitrary HTML |
| HTMLZ | Calibre-style top-level index selection, OPF metadata/cover manifest and resources | Nested HTML files remain resources; only the selected top-level document is the spine |
| DOCX | WordprocessingML to XHTML, basic styles, lists, tables, external links, relationships, images and core properties | Footnotes, tracked-change semantics, OMML, charts, advanced numbering and full Word layout are not reproduced |
| AZW4 | PDF extraction, PDF metadata/pages/reflow and `BookFormat.azw4` preservation | DRM is rejected; the wrapper does not become a new PDF renderer |
| CB7 | 7-Zip image pages, ComicInfo metadata and natural page order | 7z decompression is asynchronous and bounded per entry |
| CBC | `comics.txt` paths/titles, nested CBZ/CBR/CB7 resolution and flattened collection page order | The common `ComicBook` model exposes one page sequence rather than a multi-level collection TOC |
| ODT | OpenDocument XML paragraphs, headings, spans, links, lists, tables, images and metadata | Advanced styles, tracked changes, fields, drawings and exact page layout are outside the reflow contract |

All formats enter through `BookReader` and preserve a common model for
metadata, `Files`, navigation, reading order and statistics. CB7/CBC use the
asynchronous `openFromBytes` path because the 7-Zip API is asynchronous; the
legacy synchronous `parseBook` API reports that boundary clearly.

## Validation inventory

The focused regression suites cover:

- BOM and legacy text decoding, TXTZ OPF semantics, resource extraction,
  formatting hints, natural ordering and path traversal;
- HTML metadata, heading nesting, HTMLZ index selection, OPF merge and cover;
- DOCX relationships, images, core properties, lists, tables and typed errors;
- AZW4 PalmDB record extraction, split PDF payloads, preambles, missing PDF
  data and DRM;
- CB7 writer/reader round trips and CBC nested collection resolution;
- ODT metadata, headings, inline styles, lists, tables, images and missing
  required parts;
- `BookReader` dispatch, format detection and the web-worker wire round trip
  for `DocumentBook`.
