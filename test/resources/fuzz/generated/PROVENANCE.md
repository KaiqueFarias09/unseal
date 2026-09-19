# Generated Fuzz Fixtures — Provenance

Every file in this directory is produced byte-for-byte by
`tool/generate_fuzz_fixtures.dart` from FIXED seeds. Nothing here is
downloaded, hand-edited, or derived from any private corpus. Regenerate
with:

    dart run tool/generate_fuzz_fixtures.dart          # (re)write
    dart run tool/generate_fuzz_fixtures.dart --check  # verify drift

`--check` regenerates the plan in memory and byte-compares it with these
files; the reproducibility smoke test (`test/tooling/`) runs the same
comparison, so CI fails if a generator change silently alters committed
bytes.

Families and seeds:

| Files | Generator | Seed(s) | Exercises |
|---|---|---|---|
| `epub/epub2-basic.epub` | `buildEpub(syntheticEpubSpec(1))` | 1 | EPUB 2 OPF + NCX, 1-4 chapters |
| `epub/epub3-nav.epub` | `buildEpub(syntheticEpubSpec(2, ...))` | 2 | EPUB 3 nav document, no NCX |
| `epub/epub3-cover.epub` | `buildEpub(syntheticEpubSpec(3, ...))` | 3 | nav + PNG cover-image manifest property |
| `epub/epub-no-toc.epub` | `buildEpub(syntheticEpubSpec(4, ...))` | 4 | neither NCX nor nav |
| `zip/stored-method.zip` | `buildZip` | n/a (fixed text) | method-0 entries, archive comment |
| `zip/mixed-methods.zip` | `buildZip` | n/a | deflate + stored, entry comment, nested dirs, binary payload |
| `xml/fb2-style.fb2` | `fb2StyleSpec` | 11 | namespaces, predefined + numeric entities, CDATA, comments |
| `xml/opf-style.opf` | `opfStyleSpec` | 12 | OPF metadata, refines, xml:lang |
| `xml/dtd-internal-subset.xml` | `doctypeInternalSubsetSpec` | 13 | internal DTD entity subset, standalone declaration |
| `xml/prologue-variations.xml` | `prologueVariationSpec` | 14 | processing instruction, leading comment, no declaration |
| `xml/utf8-bom.opf` | `opfStyleSpec` | 15 | UTF-8 BOM before the declaration |
| `cfi/cfi-cases.json` | `buildCfiCaseJson` | 42 | valid + malformed EPUB CFI strings (labeled) |
| `pdf/minimal-text.pdf` | `minimalTextPdf` | n/a | single page, uncompressed content stream |
| `pdf/flate-content.pdf` | `minimalTextPdf` | n/a | `/FlateDecode` content stream |
| `pdf/lzw-content.pdf` | `minimalTextPdf` | n/a | `/LZWDecode` EarlyChange=1 content stream |
| `pdf/two-page-flate.pdf` | `twoPagePdf` | n/a | two pages, Flate content |
| `pdf/info-metadata.pdf` | `pdfWithInfo` | n/a | Info dictionary with synthetic Title/Author |
| `mobi/palmdoc-none.mobi` | `syntheticMobi(21)` | 21 | PalmDB + MOBI record 0, compression 1, EXTH 100/503 |
| `mobi/palmdoc-compressed.mobi` | `syntheticMobi(22, palmDocCompression: true)` | 22 | PalmDOC LZ77 compression (method 2) |
| `images/tiny-gray.png` | `tinyPng` | n/a | 1x1 grayscale PNG |
| `images/gradient.png` | `buildPng(8, 8, ...)` | n/a | 8x8 grayscale PNG |
| `images/tiny.jpg` | `tinyJpeg` | n/a | minimal baseline grayscale JPEG |
| `images/tiny.gif` | `tinyGif` | n/a | minimal GIF89a, 2-color global color table |
| `images/gif87a.gif` | `tinyGif(variant: 1)` | n/a | GIF87a variant |
| `images/png-bad-crc.png` | `pngWithBadCrc` | n/a | valid structure, corrupted IDAT CRC |
| `images/png-truncated-idat.png` | `pngTruncatedIdat` | n/a | cut inside IDAT, no IEND |
| `images/jpeg-truncated-scan.jpg` | `jpegTruncatedScan` | n/a | cut inside scan data, no EOI |

Titles and authors inside these fixtures are generated nonsense words
(e.g. `lirebi hakiv`) — they can never collide with real book metadata.

Validation performed when this corpus was assembled (all still asserted
by the smoke test where the library is the oracle):

- every book-shaped fixture parses via `Unseal.parse` with the
  expected synthetic metadata;
- every PDF passes `qpdf --check` and extracts its text through pypdf,
  including the LZW stream (pypdf decodes it, proving encoder
  conformance);
- every intact image decodes through macOS CoreImage (`sips`); the
  corrupt-but-parseable variants are intentionally NOT fully decodable —
  they exist to exercise lenient image sniffing paths.
