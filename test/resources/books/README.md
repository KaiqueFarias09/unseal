# Multilingual and Edge-Case Book Corpus

This directory contains redistribution-safe fixtures selected for parser,
localization, reading-direction, accessibility, and media-overlay testing.
`manifest.json` is the canonical inventory.

## Layout

- `epub/`: immutable downloaded publications
- `mobi/`: unchanged Project Gutenberg MOBI 6 and KF8 downloads
- `fb2/`: repository-authored and externally published FictionBook documents
- `comic/`: generated archives plus externally published CBZ, CBR, CB7 and CBC samples
- `txt/`, `html/`, `docx/`, `odt/`: generated fixtures for the document adapters
- `pdf/`: real-writer and externally published PDFs with redistributable content
- `licenses/`: license texts that are not already fully embedded in each publication
- `manifest.json`: provenance, expected behavior, size, and SHA-256 for every fixture

## Rules

1. Do not edit downloaded publications in place. Add a derived fixture under a different name and record
   its relationship to the source.
2. Verify every new or refreshed file with its container checker, SHA-256, and the unseal
   metadata/parser tests.
3. Keep attribution and license notices with redistributed fixtures.
4. Project Gutenberg status statements apply to the United States. The selected Gutenberg works
   are also old enough for the Brazilian life-plus-70-year term, but redistribution elsewhere must
   still be checked against local law.
5. Do not add fixtures restricted to non-commercial, private, or exemplar-only use. Every fixture
   in this corpus permits redistribution and commercial use when its recorded terms are followed.

## Coverage

| ID | Primary purpose |
|---|---|
| `RTL-AR` | Arabic shaping, bidi, RTL flow, native fonts |
| `RTL-HE` | Hebrew, mixed-direction text, RTL page progression |
| `VERT-JA` | Vertical Japanese, alternate stylesheets, RTL page progression |
| `SCRIPT-SA` | Devanagari shaping and native font fallback |
| `MO-EN` | EPUB 3 SMIL/audio synchronization |
| `CHEM-PD` | Chemistry tables, plates, notation, long-form TTS |
| `MATH-PD` | Geometry diagrams, symbols, index, pagination |
| `CHEM-RUBY` | Ruby markup around chemical formulae and fallback content |
| `ODD-PD` | Semantic markup, notes, SVG, blank and visual pages |
| `CJK-ZH` | Long Chinese text, CJK line breaking, parser stress |
| `LOCALE-PT` | Portuguese metadata, accents, punctuation, TTS |
| `LOCALE-ES` | Spanish metadata, inverted punctuation, TTS |
| `LOCALE-FR` | French metadata, elision, diacritics, TTS |
| `FXL` | Fixed layout, orientation, spreads |
| `A11Y` | Semantics, landmarks, descriptions, logical reading order |
| `FORMAT-MOBI6` | Official Project Gutenberg legacy Kindle/MOBI 6 file |
| `FORMAT-AZW3` | Official Project Gutenberg KF8/AZW3 file |
| `FORMAT-FB2` | Multilingual XML, bidi, Unicode, sections and scientific notation |
| `FORMAT-CBZ` | ZIP comic, ComicInfo metadata, cover and natural page ordering |
| `FORMAT-CBR` | RAR 4 stored/compressed entries and natural page ordering |
| `FORMAT-PDF` | Real-writer PDF text extraction, reflow and search |
| `FORMAT-TXT` / `FORMAT-TXTZ` | Text decoding, Calibre-style metadata, OPF sidecar, Markdown and resources |
| `FORMAT-HTML` / `FORMAT-HTMLZ` | HTML metadata/navigation, top-level index and OPF sidecar |
| `FORMAT-DOCX` | Open XML document, styles, metadata and resource contract |
| `FORMAT-AZW4` | PalmDB wrapper and embedded PDF delegation |
| `FORMAT-CB7` / `FORMAT-CBC` | 7-Zip pages and Calibre collection manifest |
| `FORMAT-ODT` | OpenDocument content XML and metadata |
| `REAL-FB2-WL-PL` | Unmodified Polish FB2 published by Wolne Lektury |
| `REAL-CBZ-IA-1895` | Real 1895 scanned publication distributed as CBZ |
| `REAL-CBR-IA-1909` | Real 1909 image collection using compressed RAR 4 pages |
| `REAL-PDF-EUCLID` | External Project Gutenberg PDF with geometry diagrams and pagination |

## External-file attribution

`REAL-FB2-WL-PL` is Bolesław Prus, *Dziwna historia*. Książka pochodzi z
serwisu [Wolne Lektury](https://wolnelektury.pl/katalog/lektura/prus-dziwna-historia/).
The underlying work is in the public domain; the service's editorial additions
are published under Licencja Wolnej Sztuki 1.3. See the
[Wolne Lektury usage rules](https://wolnelektury.pl/info/zasady-wykorzystania/)
and [Wolne Lektury logo](https://wolnelektury.pl/info/logotypy/).

The Internet Archive CBZ and CBR are unchanged downloads carrying Public
Domain Mark 1.0 in their item records. The mark records the uploader's
copyright-status identification; it is not a warranty for every jurisdiction.
Their exact item pages, download URLs, sizes and hashes are pinned in the
manifest.

## Known real-world limitation

`REAL-CBR-IA-1909` is a valid RAR 4 archive whose 24 JPEG page entries are
visible to system archive tools. They use ordinary non-solid RAR 2.9/3.x
compression, which the unseal CBR parser decodes. RAR VM filters, PPMd blocks,
solid entries, and encrypted entries remain explicitly unsupported and are
reported as compressed-entry limitations rather than silently returning pages.

Regenerate the synthetic comic archives with:

```sh
dart run tool/generate_synthetic_format_fixtures.dart
```

The normal test suite stays offline. Optional larger PDF corpora have their own explicit fetch
tool and manifest under `../pdf/gutenberg/`.

The older fixtures directly under `test/resources/epub/` remain separate for compatibility with
existing tests. Tests reject the known commercial books that were removed from this repository.
