# hOCR test fixtures

Three groups, each with its own provenance. Every SHA-256 below is also
pinned in `tool/reference/hocr/corpus-sha256.json`, which the D02
reference lane verifies before anything runs.

## `images/` — source images (Apache-2.0, read-only inputs)

From the official `tesseract-ocr/test` repository
(https://github.com/tesseract-ocr/test, `testing/`, retrieved 2026-10-18;
the repository is Apache-2.0):

- `phototest.tif` — 640x480, 200 dpi, clean English prose. SHA-256
  `d2241a1eb6d6cd2eb6544b8e228c2862c852b7467d16ed636caa32179b780692`.
- `eurotext.tif` — 1024x800, 300 dpi, German/French mixed text with
  diacritics and guillemets; the image the hOCR specification's baseline
  example quotes. SHA-256
  `7b9bd14aba7d5e30df686fbb6f71782a97f48f81b32dc201a1b75afe6de747d6`.
- `unlv-8071_093.3B.tif` — 3312x2550, 300 dpi magazine page: nine
  content areas, captions, a pull-out, photo and separator blocks.
  Original name `8071_093.3B.tif`. SHA-256
  `d4f01cba19c99f8894d94a6d43eb8ed8013f8cf17fc08af9346bb9fb3697d452`.
- `unlv-8087_054.3B.tif` — 2560x3300, 300 dpi magazine page: headers,
  captions, photo blocks. Original name `8087_054.3B.tif`. SHA-256
  `dab6db0f4c32296f313c7f1e7e139b13d7c69be65c64d6016f85ea67ebca9102`.

## `tesseract/` — DERIVED, not source data

Tesseract 5.5.3 (Leptonica 1.87.0, `eng.traineddata` SHA-256
`7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2`),
`-c tessedit_create_hocr=1 -c tessedit_create_tsv=1`, one execution per
image with the image file as the working-directory entry, so `image`
records bare names. `multipage.tif` is the `tiffcp` concatenation of
`phototest.tif` and `eurotext.tif` and yields two `ocr_page` elements
from one pass. `tool/hocr_reference.py` re-runs the exact commands and
fails when a committed file is not byte-identical to the fresh output.

Files: `phototest.hocr/.tsv`, `eurotext.hocr/.tsv`,
`unlv-8071.hocr/.tsv`, `unlv-8087.hocr/.tsv`, `multipage.hocr/.tsv`.

## `external/` — pre-existing sidecars (CC0-1.0)

From `kba/ocr-fileformat-samples`
(https://github.com/kba/ocr-fileformat-samples, `samples/hocr/`,
retrieved 2026-10-18; the repository is CC0-1.0 and its `.yml` sidecars
record the engine). Producers: Tesseract 3.04.01 (`060.hocr`), ABBYY
FineReader Engine 11 (`417576986_0012.hocr`), tesseract 3.05.00dev
(`417576986_0013.hocr`), ocropy 0.4 (`433934212_0017.html`), OCRopus
revision 312 (`alice.hocr`), gcv2hocr/Google Cloud Vision
(`jp_vert.hocr`), kraken 0.8.0 (`kraken_bw_example.hocr`), tesseract
3.03 (`wetzel_reisebegleiter_1901_0021.hocr`). These are somebody
else's recognition results, read as-is; nothing here was produced for
this mission.

## `derived/` — hand-written, project-authored

`features.hocr` — a derived document exercising what no corpus producer
writes: astral characters, `ins`/`del` alternatives, `textangle`,
order-2 baselines, `hardbreak`, `dir` on lines, `ocrx_block`,
`ocr_column`, mixed class lists, `xml:lang`, `x_wconf` numeric/zero/
unknown/absent side by side, single-value `scan_res`, quoted `lpageno`,
`imagemd5`, kraken-style comma titles, trailing separators, a spec-style
`ocr_header` block, a Tesseract-style `ocr_header` line, a frameless
page and a zero-extent page frame. Not producer output; it complements,
never replaces, the corpus.
