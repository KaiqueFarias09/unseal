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

## MiniSearch

The per-publication search index in `lib/src/features/search/index/` is a Dart
port of the core of [MiniSearch](https://github.com/lucaong/minisearch) at
revision `3d239d1c3ae7aef1bf5d8945dd7b5f0709f646f5`: the radix tree
(`SearchableMap`, including the bounded Levenshtein trie walk of
`fuzzySearch`), the BM25+ scoring with its default parameters, and the
prefix/fuzzy expansion weighting. The port replaces the document model with
Unseal's per-section postings over canonical UTF-16 ranges, drops the original's
relative-view-key weighting quirk (stated in `index_ranking.dart`), and prunes
the fuzzy walk explicitly where the original relied on typed-array
out-of-bounds writes. Copyright 2022 Luca Ongaro. MiniSearch is licensed under
the MIT license; the text is included at `licenses/minisearch-MIT.txt`.

## Tantivy

Tantivy ([quickwit-oss/tantivy](https://github.com/quickwit-oss/tantivy) at
revision `e1acb3e0112f2b4819946aa4ea5742bf429853d8`) serves as the design
reference for the positioned-postings model of the same search index: what the
postings store (per-section term frequencies and occurrence positions) and the
BM25 field statistics they must carry for scoring. No Tantivy source code is
copied; the Dart implementation follows Unseal's own structures. Tantivy is
licensed under the MIT license; the text is included at
`licenses/tantivy-MIT.txt`.

## Hypothesis client

The durable-anchor resolution in
`lib/src/features/annotations/durable/` ports the anchoring *approach* of the
[Hypothesis client](https://github.com/hypothesis/client) at revision
`a7b7400d0d706d4357ec37c2a3610b25dcca89d5`, chiefly
`src/annotator/anchoring/match-quote.ts`: a selection survives content
changes through its quote plus surrounding context, re-found with a bounded
approximate match when the exact text no longer occurs. The Dart
implementation works on the canonical text snapshots of the common text
contract instead of a browser DOM, uses sampled exact-gram seeding with a
free-start edit distance instead of `approx-string-match`'s full search, and
is deliberately stricter where the campaign contract requires it:
indistinguishable ties stay ambiguous and report candidates rather than
picking the first match, and every migrated position reports itself as not
verified.

The comparison runs for real: `tool/hypothesis_anchor_compare.dart` executes
the pinned `matchQuote` in Node against Unseal's resolver over the licensed
Gutenberg corpus (see `tool/reference/hypothesis_anchor_oracle/README.md`).
On its case matrix both implementations anchor identical offsets for exact,
corrected (small edit distance), re-wrapped, repeated-with-context, astral
and removed-target cases; the only divergence is the declared stricter
policy — with byte-identical context around two occurrences, the oracle
returns the leftmost occurrence and Unseal reports two indistinguishable
candidates. Hypothesis is BSD-2-Clause with separately licensed
subcomponents; the text is included at
`licenses/hypothesis-client-BSD-2-Clause.txt`.

## Readium Kotlin

[Readium's kotlin-toolkit](https://github.com/readium/kotlin-toolkit) at
revision `89b96c20c447d0aec17db57a06456b7decffde4c` serves as the design
reference for separating a locator's identity (which work, which revision)
from its position (which occurrence, which range) in the durable anchor
envelope. No Readium source code is copied, and nothing here claims Readium
conformance — the locators, position lists and DRM machinery of that toolkit
are outside this subset. Readium Kotlin is BSD-3-Clause; the text is included
at `licenses/readium-kotlin-BSD-3-Clause.txt`.

## W3C Web Annotation Data Model

The selector adapter in
`lib/src/features/annotations/durable/w3c_annotation_adapter.dart` implements
the declared subset (TextQuoteSelector with exact/prefix/suffix,
TextPositionSelector) of the [W3C Web Annotation Data Model
Recommendation](https://www.w3.org/TR/annotation-model/): positions count
Unicode code points over normalized text in logical order. The spec is cited
as the external contract, not vendored; the conversion and validation code is
Unseal's own.

## rardecode

The RAR 5 decompressor in `lib/src/features/comic/archive/rar5_decoder.dart`
is a bounded Dart adaptation of the [rardecode](https://github.com/nwaples/rardecode)
Go implementation (BSD-2-Clause), pinned at `ad22ba91a2ab`
(`decode50.go`, `decode_reader.go`, `huffman.go`, `bit_reader.go`, and the
V5 filters of `filters.go`). Copyright 2015, Nicholas Waples. The license
text is included at `licenses/rardecode-BSD-2-Clause.txt`. `tool/rar5_compare.dart`
builds the same pinned revision as the mandatory extraction oracle.

## libarchive

The RAR 5 container walk (`rar5_archive.dart`) and the fixture corpus
under `test/resources/books/comic/rar5/` were cross-checked against
[libarchive](https://github.com/libarchive/libarchive) at pinned commit
`87dec938e1578901f4919faa76e5f541b4d145b1`; no libarchive code is
copied — it serves as the second independent decoder (through `bsdtar`)
and the source of the real RAR 5 test archives (uudecoded from
`libarchive/test/`, unmodified apart from the `libarchive-` filename
prefix). The libarchive COPYING is included at
`licenses/libarchive-COPYING`. See
`test/resources/books/comic/rar5/PROVENANCE.md` for per-file provenance.
