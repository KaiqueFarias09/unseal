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
