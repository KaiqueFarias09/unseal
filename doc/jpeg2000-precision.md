# JPEG 2000 precision and subsampling

This document fixes the contract the `JPXDecode` codec follows for unsigned
8- to 16-bit components and subsampled component grids (ISO/IEC 15444-1
Part 1, JP2 sYCC), and the comparison protocol its acceptance uses. The
policies here were written before the decoder code; the comparison tooling
reads them, it does not define them.

Reference implementation: OpenJPEG `openjp2` 2.5.4 (Homebrew `openjpeg`
2.5.4_1, binaries `/opt/homebrew/bin/opj_decompress`,
`/opt/homebrew/bin/opj_compress`, library `libopenjp2.2.5.4.dylib`; source
tag `v2.5.4`, commit `6c4a29b00211eb0430fa0e5e890f1ce5c80f409f`). OpenJPEG
is a development tool only: the library stays pure Dart and never calls
it at runtime.

## Scope

Accepted (decoded, compared against the reference):

- Component precision 8 to 16 bits, unsigned (`Ssiz` 7..15 with the sign
  bit clear), uniform across components.
- Per-component sample grids `XRsiz`/`YRsiz` from 1 to 255, image offsets
  `XOsiz`/`YOsiz`, tile grids and tile offsets, odd image and tile sizes,
  partial edge tiles.
- One component (grayscale) or three components (RGB, or sYCC).
- JP2 `colr` enumerated colourspaces 16 (sRGB), 17 (greyscale) and 18
  (sYCC). sYCC is accepted with the 4:4:4, 4:2:2 (`dx` 1,2,2 / `dy` 1,1,1)
  and 4:2:0 (`dx` 1,2,2 / `dy` 1,2,2) chroma layouts.
- RCT and ICT when the three components share the same grid
  (`dx`, `dy`, width and height identical).
- Everything the 8-bit subset already accepted: 5/3 and 9/7 wavelets,
  LRCP/RLCP, quality layers, precincts, SOP/EPH, segmentation symbols,
  COD/COC and QCD/QCC overrides.

Refused with a typed failure (`JpxUnsupportedException`, a `PdfException`):
signed components, precision below 8 or above 16, components with mixed
precision, 2 or more than 3 components, ICC profiles (`colr` method 2),
palettes (`pclr`/`cmap`), channel definitions (`cdef`, alpha), Part 2
capabilities, sYCC with a chroma layout other than the three above, and the
coding styles the 8-bit subset already refused (arithmetic bypass, PPM/PPT,
POC, RGN). A multiple component transform over components whose grids
differ is corruption, not a feature, and raises `JpxException` (OpenJPEG
aborts the tile with "Tiles don't all have the same dimension").

## Native sample contract

The decoder exposes one native plane per component:

| Field | Meaning |
| --- | --- |
| `precision` | Bits per sample shared by every component, 8 to 16. |
| `component.dx`, `component.dy` | `XRsiz`, `YRsiz` from SIZ. |
| `component.x0`, `component.y0` | `ceil(XOsiz / dx)`, `ceil(YOsiz / dy)`. |
| `component.width`, `component.height` | `ceil(Xsiz / dx) - x0`, `ceil(Ysiz / dy) - y0` (equation B-2). |
| `component.samples` | Row-major `Uint8List` when `precision <= 8`, `Uint16List` otherwise. |

Native samples are the level-shifted, clipped integers in
`[0, 2^precision - 1]` that the codec reconstructs: exactly what
`opj_image_comp_t.data` holds after `opj_decode`, before any utility
post-processing. No scaling, dithering or re-quantisation happens on this
path. 16-bit content is compared on these planes; nothing is reduced to 8
bits before the comparison.

## Output contract

The PDF adapter projects the native planes onto the reference grid
(`Xsiz - XOsiz` by `Ysiz - YOsiz` samples) and encodes a PNG:

1. **Precision 8** produces the same 8-bit PNG as before (colour type 0 or
   2). The committed 8-bit corpus and the browser pixel hash pin this.
2. **Precision 9 to 16** produces a 16-bit PNG. Samples are scaled by left
   bit replication, `v16 = (v << (16 - p)) | (v >> (2p - 16))`, and an
   `sBIT` chunk declares `p` significant bits (omitted when `p = 16`). The
   native value is recoverable as `v16 >> (16 - p)`; the PNG is a projection
   for viewers and is never the object of the precision comparison.
3. **Subsampled components that are not sYCC** are upsampled to the
   reference grid by nearest-neighbour replication with the phase of
   `opj_decompress -upsample`: sample `i` of a component covers reference
   columns `[dx * (x0 + i), dx * (x0 + i + 1))`, columns before
   `dx * x0 - XOsiz` are filled with 0 when the image origin is not a
   multiple of `dx` (an OpenJPEG quirk kept for parity; `XOsiz` is 0 in
   practically every real file), and the last sample extends to the right
   and bottom edges.
4. **sYCC** is converted to RGB at the luma resolution with the integer
   arithmetic of OpenJPEG `color.c` (`sycc444_to_rgb`, `sycc422_to_rgb`,
   `sycc420_to_rgb`): `Cb`/`Cr` are offset by `2^(p-1)`, each term is
   `(int)(k * value)` with C truncation toward zero, results clip to
   `[0, 2^p - 1]`, chroma is replicated to the 2x2 (4:2:0) or 2x1 (4:2:2)
   luma positions it covers, and the first column (odd `XOsiz`) or first
   row (odd `YOsiz`) uses `Cb = Cr = 0` as the reference does. This is a
   documented parity policy, not a colour-science claim.
5. **Which three-component images are sYCC.** JP2 `colr` 18 is sYCC. In
   addition, any three-component image with the 4:2:2 or 4:2:0 chroma
   layout above (first component `dx = dy = 1`, second and third
   subsampled) is treated as sYCC regardless of the wrapper, because that is
   the `opj_decompress` rule that PDF readers built on OpenJPEG (pdf.js)
   apply and the layouts its converter accepts. Three-component images
   outside that rule and outside `colr` 18 are RGB and follow rule 3 (this
   includes three components that are all subsampled by the same factor,
   which `opj_decompress` labels sYCC but cannot convert and writes as is).
   `colr` 18 with any other layout is refused.

Only rules 1 and 2 touch the sample values of a dx = dy = 1 image; rules 3
to 5 are declared here so the acceptance can compare each lane separately.

## Comparison protocol

Three lanes, compared separately, each with its own reference artefact:

| Lane | Unseal side | Reference | Lossless | Lossy |
| --- | --- | --- | --- | --- |
| native | per-component native planes | `opj_oracle dump` (libopenjp2 2.5.4, no post-processing) | exact | max abs error ≤ 3, RMSE ≤ 0.5 per component |
| upsample | reference-grid planes of non-sYCC subsampled images | `opj_decompress -upsample -o *.rawl` | exact | same ceilings as native |
| rgb | converted RGB planes of sYCC images | `opj_decompress -o *.rawl` (sYCC conversion applied) | exact | max abs error ≤ 4, RMSE ≤ 1.0 per component |

The lossy ceilings are absolute sample levels and do not scale with
precision. They are the ceilings the 8-bit corpus fixed in 2026-10 (3 /
0.5, global cap 4 / 1.0): a float32 pipeline that mirrors the reference
differs by rounding flips of one level, not by a fraction of the range, so a
precision- or grid-level mistake (wrong dequantisation exponent, wrong
`dx`, wrong tile offset, wrong level shift) produces errors far above them.
The rgb lane adds the propagation of a one-level native difference through
the 1.402 / 1.772 gains and the truncation. Loosening any ceiling after a
Dart run invalidates the acceptance; tightening is always allowed.

Every lossy fixture has a lossless sibling with the same geometry, so grid
and precision correctness is proven exactly and the lossy lane only
measures the 9/7 pipeline.

Refused inputs are counted as expected rejections, never as compared
samples. The comparator itself is covered by negative cases: a missing
reference artefact, a reference command that exits non-zero, and a
deliberately corrupted reference payload must each fail the run.

## Corpus

Fixtures live in `test/resources/pdf/jpeg2000/precision/` with their
reference payloads in `oracle/`, the fixture matrix in `corpus.json`, the
ceilings in `tolerances.json` and hashes in `MANIFEST.md`.
`tool/generate_jpx_precision_fixtures.dart` regenerates and verifies all of
them; the committed files are the acceptance inputs.

Producers:

- `tool/jpx_oracle/opj_oracle encode` — libopenjp2 2.5.4 driven through
  its public API so each component keeps its own grid, including odd sizes
  and odd origins the `opj_compress` raw reader cannot express.
- `ffmpeg` 9.0.2 (native `jpeg2000` encoder, GPL build) — the independent
  producer: 16-bit grayscale, 16-bit RGB, 8/10/12-bit sYCC 4:2:0 and 4:2:2
  JP2 files derived from the public-domain NASA Apollo 17 photograph already
  committed as `test/resources/pdf/jpeg2000/src/real-rgb128.ppm`.
- The synthetic sample generator is the seeded LCG gradient-plus-bars
  pattern of the 8-bit corpus, extended to the target precision.

Synthetic fixtures are named `synth-*`, photograph derivatives `real-*`.
The 8-bit corpus in the parent directory is unchanged and keeps its tests.

## Limits

Every allocation is budgeted before it happens, with arithmetic that stays
exact on JavaScript doubles:

- input payload ≤ 256 MiB (unchanged);
- per-component native samples ≤ 2^28 and total native bytes ≤ 256 MiB;
- tile work buffers ≤ 256 MiB per tile across components (unchanged, now
  computed on each component's own grid);
- reference-grid output (upsampled or RGB planes) ≤ 256 MiB and PNG raw
  scanlines ≤ 256 MiB, each checked before the stage allocates;
- `dx`/`dy` in 1..255, precision in 8..16, tile and component counts as
  before;
- code-block bit-planes stay below 31 so the 2x coefficient convention
  never overflows a 32-bit integer.

Declared sizes beyond a budget raise the single budget message; truncated or
corrupt streams raise `JpxException`; features outside the scope raise
`JpxUnsupportedException`. No path returns invented pixels.

## Evidence

`tool/jpx_precision_compare.dart` runs the three lanes over the corpus, the
negative comparator cases, the PDF/session/browser integration suites and
the isolated benchmark, and writes `build/evidence/C04/comparison.json`
with the current HEAD. `tool/jpx_precision_reference.dart` executes the
OpenJPEG reference and writes `build/evidence/C04/reference.json`. Both are
the `reference` and `compare` stages of the campaign manifest.
