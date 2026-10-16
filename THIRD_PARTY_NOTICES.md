# Third-party notices

## jchmlib

The CHM container and LZX implementation in `lib/src/features/chm/` was
developed with the [jchmlib](https://github.com/chimenchen/jchmlib) Java
implementation as a behavior and algorithm reference. The Dart code is a
bounded adaptation for Unseal's reading model and VM/browser runtimes.

Copyright 2017 chimenchen. jchmlib is licensed under Apache License 2.0.
The license text is included at `licenses/jchmlib-APACHE-2.0.txt`.

The PuTTY CHM test fixture has its own notice in
`test/resources/books/licenses/putty-chm-LICENSE.txt`.

## djvu-rs

The JB2 ZP arithmetic-coder state-table constants in
`lib/src/features/djvu/zp_tables.dart` were cross-checked and transcribed from
the independent [djvu-rs](https://github.com/matyushkin/djvu-rs) implementation
as protocol data. Its MIT license is included in `licenses/djvu-rs-MIT.txt`.
The JB2 decoding logic itself was implemented in pure Dart from the DjVu 3
specification; no DjVuLibre GPL source is copied.

## PdfPig

The PDF page-structure layer in `lib/src/features/pdf/layout/` (word
extraction from glyph advances, the Docstrum bottom-up segmentation, and
the reading-order XY-cut) was ported from the
[PdfPig](https://github.com/UglyToad/PdfPig) C# implementation at revision
`3452b9fb52440202fa30b8dd8bf57c5186f8de29`, chiefly
`UglyToad.PdfPig.DocumentLayoutAnalysis`. The algorithms were adapted to
word components on Unseal's own content-stream parser; no PdfPig parser
code is copied. PdfPig is licensed under Apache License 2.0; the license
text is included at `licenses/pdfpig-APACHE-2.0.txt`. The dump oracle in
`tool/reference/pdfpig_layout_dump/` runs PdfPig as an external
development tool.

## Tabula

The table detection in `lib/src/features/pdf/layout/pdf_table_detector.dart`
ports the algorithms of [tabula-java](https://github.com/tabulapdf/tabula-java)
at revision `2cdf3b4fd3f7e921dca8cc6814cdd9316be40f0f` —
`SpreadsheetExtractionAlgorithm` (ruling lattices), `BasicExtractionAlgorithm`
(vertical rulings plus text rows) and its whitespace-aligned fallback. The
port works on Unseal's own words and ruling lines. tabula-java is licensed
under the MIT license; the text is included at `licenses/tabula-java-MIT.txt`.
