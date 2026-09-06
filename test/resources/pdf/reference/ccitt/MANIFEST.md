# CCITT (Group 3/4 fax) reference fixtures

Real-world PDFs exercising the `CCITTFaxDecode` image filter, copied
verbatim from the pdf.js test corpus and used both by
`test/tests/pdf/pdf_ccitt_test.dart` (decode + placement) and by the
image parity harness (`dart run tool/pdf_parity.dart --image`, oracle in
`tool/reference/`). pdf.js is Apache-2.0; each file below names its
upstream path. Files are shared test data, not content we generated.

| File | pdf.js source path | CCITT params | Provenance / license |
| --- | --- | --- | --- |
| `ccitt_EndOfBlock_false.pdf` | `test/pdfs/ccitt_EndOfBlock_false.pdf` | `/K -1`, `/EndOfBlock` true and false variants, 81x26 | pdf.js corpus (Apache-2.0), regression test for issue #14451 |
| `images_1bit_grayscale.pdf` | `test/pdfs/images_1bit_grayscale.pdf` | `/K -1`, 134x39, `/BlackIs1` false and true variants | pdf.js corpus (Apache-2.0), covers `/BlackIs1` inversion |
| `issue4379.pdf` | `test/pdfs/issue4379.pdf` | `/K -1`, 1000x800 `/ImageMask` | pdf.js corpus (Apache-2.0), regression test for issue #4379 |
| `issue13372.pdf` | `test/pdfs/issue13372.pdf` | `/K -1`, 646x761 `/ImageMask` | pdf.js corpus (Apache-2.0), regression test for issue #13372 |

Placed-image expectations (what `pdf_content_stream.dart` actually
draws per fixture):

| File | placed image objects | notes |
| --- | --- | --- |
| `ccitt_EndOfBlock_false.pdf` | 6-11 (81x26, /K -1 / 0 / 1) | all six CCITT images are drawn |
| `issue4379.pdf` | none placed (object 1 is only a /Mask of obj 2) | kept for the mask-parse path |
| `issue13372.pdf` | 14 (646x761 /ImageMask) | drawn inside a shading pattern |
| `images_1bit_grayscale.pdf` | 9, 10 (134x39) and 12 (105x39 /ImageMask) | inline images and Flate masks are not extracted |

`/K -1` is Group 4 (T.6) coding in most fixture images; Group 3 1D/2D
variants are covered by unit tests in `pdf_ccitt_test.dart` (built with
`PdfFixtureBuilder`).
