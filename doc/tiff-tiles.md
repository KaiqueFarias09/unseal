# TIFF and BigTIFF tiled rasters

This document fixes the contract for tiled TIFF/BigTIFF pages: which
layouts decode, which fail typed, how the decoder is bounded, and how its
pixels are compared against libtiff. It complements the README (public
contract) and `test/resources/tiff/PROVENANCE.md` (fixture origin).

## Layouts

A page is tiled when its IFD carries `TileWidth` (322) and `TileLength`
(323). Tile data is addressed by `TileOffsets` (324) and `TileByteCounts`
(325); when either array is absent the decoder reads `StripOffsets` (273)
or `StripByteCounts` (279) in its place, because libtiff stores both tag
pairs in one field and files written by the Silicon Graphics Image Library
(`cramps-tile.tif`, `quad-tile.tif`) only carry the strip tags.
`RowsPerStrip` is ignored on tiled pages.

The grid is `ceil(width / tileWidth)` tiles across and
`ceil(height / tileLength)` tiles down, in row-major order. Each tile
decodes to its full footprint (`tileLength` rows of `tileWidth` pixels),
including the padding of right and bottom edge tiles, before the page
raster takes the visible part. Tile dimensions that are not multiples of
16 are accepted on read, as libtiff accepts them with a warning.

Tiled pages share the strip codecs: uncompressed, PackBits, LZW,
Deflate/AdobeDeflate, horizontal differencing (Predictor 2) on byte-aligned
samples, and CCITT modified Huffman, Group 3, and Group 4 on bilevel pages.
A CCITT tile is decoded with the tile width as its row length. Sample
layouts match strips: PlanarConfiguration 1; gray 1, 2, 4, 8, and 16 bits
(PhotometricInterpretation 0 or 1); RGB 8 and 16 bits (2); up to four
samples per pixel, with extra samples ignored. `SampleFormat` 1 (unsigned)
and 4 (void) are read as unsigned integers, which is how libtiff treats the
obsolete SGI `DataType` tag that `tiffcp` re-emits as `SampleFormat 4`.

Orientation (274) is honored for the four top-left/top-right/bottom-right/
bottom-left values: 1 is stored as is, 2 is mirrored horizontally, 3 is
rotated 180 degrees, and 4 is mirrored vertically, so every page image is
top-left. The transposed orientations 5-8 fail with
`TiffUnsupportedCodecException`; libtiff itself reads them as their
untransposed counterparts, so no independent oracle exists for them.

`FillOrder` 2 fails typed for every codec. Previously only the CCITT path
checked it; sub-byte samples under any other codec would have been read
bit-reversed without notice.

Multi-page documents keep IFD order; every page is independently stripped
or tiled.

## Rejections before allocation

Every check below runs before the corresponding buffer exists and fails
with `TiffException`:

- missing `TileOffsets`/`StripOffsets` or `TileByteCounts`/`StripByteCounts`;
- array lengths that differ from the tile count;
- a tile with a zero or negative byte count, or a range beyond the file;
- a tile range that overlaps the file header or the page's own IFD table;
- tile ranges of the same page that overlap each other;
- `TileWidth`/`TileLength` outside `1..256,000,000`, or a tile footprint
  above 256 megapixels;
- a tile footprint, page raster, or conversion buffer that does not fit the
  remaining document budget (see below);
- a tile that decodes short of its footprint. Output beyond the footprint
  is cut at the footprint for every codec; Deflate stops inflating at the
  footprint instead of inflating first and checking later.

`TiffUnsupportedCodecException` keeps naming the layouts outside the
contract: planar 2, palette, SampleFormat 2/3/5/6, LogLuv, JPEG tiles and
JPEGTables, old-style JPEG, FillOrder 2, orientations 5-8, uncompressed-mode
CCITT extensions, and every other compression id.

## Budgets

`TiffDecodeBudget` keeps four independent counters for one document:

| Counter | Limit | What it counts |
| --- | --- | --- |
| decoded pixels | 256,000,000 | width x height of every decoded page |
| resident bytes | 128 MiB | materialized BMP pages plus the live RGB conversion buffer and the live tile or strip scratch buffer; scratch and conversion bytes are released when the page completes |
| decode work | 512 MiB | every decoded segment at its full footprint, padding included, never released |
| JPEG passthrough | 32 MiB per page | counted in resident bytes |

The work counter is what stops a small image from being paid for as a
large one: a 1x1 page with 8192x8192 tiles costs 64 MiB of work per page,
so nine such pages fail typed even though their BMPs are 58 bytes each.

## Comparison contract

Reference: libtiff 4.7.2 (`/opt/homebrew/Cellar/libtiff/4.7.2`,
`TIFFLIB_VERSION 20260627`). `tiffinfo` records the layout of every
fixture, `tiffcp` derives identified variants, and
`tool/reference/tiff_oracle_dump/tiff_oracle_dump.c` extracts pixels at
two levels:

- native: `TIFFReadTile`/`TIFFReadScanline` samples (codec and predictor
  applied, host byte order, FillOrder normalized, sub-byte samples unpacked
  one per byte, no orientation applied);
- rgba: `TIFFReadRGBAImageOriented(ORIENTATION_TOPLEFT)`.

Unit of comparison: one RGB888 pixel of the page image Unseal emits,
rows reordered top-down from the BMP. Tolerance: zero. A case passes only
when every pixel of every page matches and the pixel count equals
`width x height` per page.

Normalization applied to the native samples before the comparison:

| Layout | Native sample `v` to expected RGB |
| --- | --- |
| gray 8-bit, photometric 1 | `(v, v, v)` |
| gray 8-bit, photometric 0 | `(255 - v)` |
| gray 1/2/4-bit | `v * 255 / (2^bits - 1)` (integer division), inverted for photometric 0 |
| gray 16-bit | `v >> 8` (high byte), inverted for photometric 0 |
| RGB 8-bit | `(r, g, b)`, extra samples dropped |
| RGB 16-bit | high byte per channel |
| orientation 2/3/4 | the native raster is flipped the same way before comparing |

The rgba lane compares directly (alpha ignored) for every layout except
RGB 16-bit, where libtiff rounds `(v + 128) / 257` while the native rule
truncates; that difference is recorded as `expected-difference`, not as a
mismatch. gray 16-bit matches both lanes because libtiff also keeps the
high byte.

Verdicts: `pass` (pixels compared, zero differences), `expected-rejection`
(Unseal fails with the declared typed exception and libtiff either also
fails or decodes a layout outside the contract), `expected-difference`
(documented above), `diverged` (any other outcome). Rejections count no
pixels. A reference dump that is missing, a reference command that fails,
or a dump whose bytes are altered makes the comparator fail; the
comparator proves this with three negative cases in its own run.

## Corpus

Tracked under `test/resources/tiff/tiled/` with SHA-256 and origin in
`test/resources/tiff/PROVENANCE.md`:

- independent files written by the Silicon Graphics Image Library and
  shipped in libtiff's `pics-3.8.0` set (`cramps-tile.tif`,
  `quad-tile.tif`, `zackthecat.tif`), plus their strip counterparts and
  real sources used for derivation (`cramps.tif`, `ladoga.tif`,
  `fax2d.tif`);
- identified derivatives transcoded with libtiff 4.7.2 (`tiffcp` and the
  mission's `tiff_oracle_encode` for layouts `tiffcp` cannot write) from
  deterministic in-repo patterns and from the independent sources: both
  byte orders, classic and BigTIFF, every codec of the matrix, edge tiles,
  images smaller than one tile, orientation 1-8, multi-IFD mixes of strips
  and tiles.

The reference stage of the oracle gate copies every tracked fixture
read-only into `build/evidence/C03/inputs/`, checks its SHA-256 against
the provenance list, derives the extra matrix into
`build/evidence/C03/derived/`, and records every command, exit code, log
hash, and dump hash in `build/evidence/C03/reference.json`.

## Commands

```sh
cc -O2 -o build/oracle/tiff_oracle_dump tool/reference/tiff_oracle_dump/tiff_oracle_dump.c \
  -I/opt/homebrew/include -L/opt/homebrew/lib -ltiff
python3 tool/tiff_tiles_reference.py --out build/evidence/C03
dart run tool/tiff_tiles_compare.dart --reference build/evidence/C03/reference.json \
  --out build/evidence/C03/compare
dart run tool/tiff_tiles_evidence.dart --out build/evidence/C03
dart run benchmark/tiff_tiles_benchmarks.dart --out build/evidence/C03/bench.json
```

`tool/tiff_tiles_evidence.dart` runs the comparator, the acceptance test
groups, the freshly compiled browser worker under Chrome, and the
benchmark, and writes `build/evidence/C03/comparison.json` with one verdict
per acceptance ID and the artifacts each verdict rests on.

## Outside this contract

Planar configuration 2, palette, float and LogLuv samples, JPEG (new or
old) tiles, OCR, region or viewport rendering, external byte sources for
TIFF, and transposed orientations are not decoded. Sparse files (tiles
with a zero byte count) are rejected rather than filled.
