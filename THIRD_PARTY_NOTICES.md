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
