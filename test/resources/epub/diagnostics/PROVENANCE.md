# EPUB diagnostics fixture provenance

Every `.epub` in this directory is a deterministic synthetic fixture
generated locally by `tool/generate_epub_diagnostics_fixtures.dart`. No
third-party or downloaded bytes are included. Regenerate with
`dart run tool/generate_epub_diagnostics_fixtures.dart`; the generator
rewrites every file bit-for-bit and refreshes `manifest.json`.

`manifest.json` records, per fixture: size, SHA-256, EPUB family, the
expected reading outcome (`readable` or `typed-failure`), and the
`expected_rules` that `diagnoseEpubArchive` must report. Those expectations
were fixed before the diagnostics engine was implemented and are the
pre-registered input of the oracle comparison
(`doc/epub-diagnostics.md`). The EPUBCheck 5.4.0 oracle outputs for these
exact bytes confirmed each mapping documented there.

The fixtures exercise one structural condition each (plus one clean EPUB 2
and EPUB 3 baseline and one Unicode/percent-encoding path exercise). They
are deliberately minimal and are not evidence of interoperability with
arbitrary authoring tools.
