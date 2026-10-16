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
