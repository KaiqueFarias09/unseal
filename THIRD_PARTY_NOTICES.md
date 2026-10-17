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

## OpenJPEG

The JPEG 2000 decoder in `lib/src/features/pdf/codec/jpeg2000/` is a pure-Dart
port of a pinned [OpenJPEG](https://github.com/uclouvain/openjpeg) revision
(8314119b067c0fc77834731168daaebd379fdb12) developed for Unseal's reading model
and VM/browser runtimes. The MQ coder state table and lifting constants are
transcribed protocol data; acceptance compares decoded output against OpenJPEG
oracle payloads. OpenJPEG is licensed under BSD-2-Clause; the license text is
included at `licenses/openjpeg-LICENSE`.
