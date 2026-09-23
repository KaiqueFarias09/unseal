# CHM fixtures

`putty.chm` is the unchanged PuTTY manual from the `chmv` test corpus. Its
redistribution terms and copyright notice are in
`../licenses/putty-chm-LICENSE.txt`; its source, URL, size, and SHA-256 are in
the book manifest.

`legacy-cp1251.chm`, `legacy-cp1252.chm`, and `legacy-cp1256.chm` are generated
by `tool/generate_chm_legacy_fixtures.dart` from original short strings and
topic names. Their `#SYSTEM` locale records are Russian (`0x0419`), English
(`0x0409`), and Arabic (`0x0401`) respectively. The generated containers have
no third-party creative content and are covered by the repository MIT license.
Their exact sizes and SHA-256 values are recorded in `../manifest.json`.

Intel E8 decoder regressions construct small uncompressed LZX frames in memory
through `test/tests/chm/chm_fixture_builder.dart`. Those byte streams exercise
the Microsoft E8 header and both positive and negative transformed relative
addresses; they are generated test inputs rather than standalone CHM books.

The redistributable PuTTY CHM was checked as a real-file candidate. Its first
LZX stream header has the Intel E8 flag clear, so it does not exercise the
translation path. The unchanged file is 271,652 bytes with SHA-256
`317147468e9876d0465b3f1457b948e43911f3e713011d574fd325fab304ef34`, matching
the book manifest. No additional CHM was added: the Free Pascal `paslzxcomp`
compressor explicitly writes zero for the Intel preprocessing flag, and no
redistributable real CHM with the flag set was verified. See the open research
item in `docs/format-parser-references.md`, the [Free Pascal compressor
source](https://gitlab.com/freepascal.org/fpc/source/-/blob/dcb91d0b52/packages/chm/src/paslzxcomp.pas),
and the [Microsoft E8 rules](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-patch/e6c8366d-a8c3-4f34-aa5d-56f44f938a09).
