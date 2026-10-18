# TIFF planar RGB and palette pages

This document fixes the contract for the two raster layouts D03 adds to
the TIFF/BigTIFF decoder: RGB stored in separate planes
(`PlanarConfiguration` 2) and palette-color pages
(`PhotometricInterpretation` 3). It complements `doc/tiff-tiles.md`
(tiled rasters, codecs, budgets, and the libtiff comparison contract),
the README (public contract), and `test/resources/tiff/PROVENANCE.md`
(fixture origin). Everything that document fixes for strips and tiles —
segment addressing, codecs, rejections before allocation, the four
budget counters, and the two comparison lanes — applies here unchanged;
only the deltas are written down.

## Planar RGB (PlanarConfiguration 2)

A planar page stores `SamplesPerPixel` separate planes, plane by plane.
The decoder accepts exactly the layout libtiff reads as plain RGB:

- `PlanarConfiguration` 2, `PhotometricInterpretation` 2 (RGB),
  `SamplesPerPixel` 3, `BitsPerSample` 8 or 16 (equal across planes),
  `SampleFormat` 1 (unsigned) or 4 (void);
- strips and tiles, classic TIFF and BigTIFF, both byte orders;
- codecs none, PackBits, LZW, Deflate/AdobeDeflate, with Predictor 1
  or 2. Predictor 2 accumulates within one plane: the stride is one
  sample (libtiff's `sp->stride` is `samplesPerPixel` only for
  contiguous data), so 16-bit carries propagate through the plane's
  own high bytes.

Segment addressing follows the normative plane-major order: the
offset/count arrays hold the whole grid of plane 0 first, then plane 1,
then plane 2, row-major inside a plane, exactly as TIFF 6.0 orders
`StripOffsets`/`TileOffsets` for separate planes. The whole array of
every band is validated (length = grid x 3, file bounds, header,
directory, and mutual overlap — across bands too) before any band is
decoded. Tiles decode at their full per-plane footprint
(`tileLength` rows of `tileWidth` samples, edge padding included)
before the page raster takes the visible part of each band.

Explicitly outside the recorte, failing with
`TiffUnsupportedCodecException` and leaving the published contiguous
behavior untouched: planar pages that carry `SamplesPerPixel` 2 or 4
(alpha and extra samples in separate planes), single-sample planar
degeneracies, sub-byte planar RGB (a `TiffException`, matching the
contiguous rule), planar CCITT or JPEG, and transposed orientations.

## Palette pages (PhotometricInterpretation 3)

A palette page maps indices through the ColorMap:

- `SamplesPerPixel` 1 (anything else is a `TiffException`), `BitsPerSample`
  1, 2, 4, or 8, indices packed most-significant-bit first;
- ColorMap (320) holds exactly `3 * 2^BitsPerSample` SHORT values —
  three 16-bit tables in red, green, blue order. The count is checked
  before the list is allocated; missing, truncated, or oversized tables
  fail with `TiffException`;
- strips and tiles, classic and BigTIFF, both byte orders, codecs none,
  PackBits, LZW, Deflate/AdobeDeflate with Predictor 1;
- orientation 1-4 brought to top-left; FillOrder 2 and transposed
  orientations fail typed as everywhere else.

The native 16-bit ColorMap values are preserved and compared exactly.
The display projection is libtiff 4.7.2's, fixed by probe before
implementation: when every entry of all three tables is at most 255,
the values are used directly as 8-bit colors (libtiff's
"Assuming 8-bit colormap" legacy path, reproduced explicitly rather
than silently); otherwise each entry projects as `v >> 8`, the same
high-byte rule as gray16 and RGB16. Index projection therefore always
agrees with `TIFFReadRGBAImageOriented` and the RGBA lane carries zero
tolerance.

Outside the recorte, failing typed: 16-bit palettes and other depths,
palette pages with more than one sample per pixel, palette + CCITT
(CCITT stays a bilevel layout), palette + JPEG passthrough, and
Predictor 2 on palette indices (normatively meaningless; libtiff
applies it, Unseal refuses rather than guess).

## Budgets

The four counters of `doc/tiff-tiles.md` are unchanged. What counts:

- pixels: page `width x height` as before;
- resident bytes: the kept BMP plus, live simultaneously during a
  page, the RGB conversion buffer, all three planar band buffers at
  their full segment footprints (codec scratch copies included), and
  on palette pages the three native ColorMap lists plus the derived
  8-bit lookup tables; all released when the page completes;
- decode work: every band segment at its full footprint, padding
  included (tiles: grid x 3 footprints; strips: `width x height x
  3 x bytesPerSample` total);
- palette validation allocates nothing before the ColorMap count
  check passes.

## Comparison contract

Reference: libtiff 4.7.2, the same `tiff_oracle_dump` lanes as C03,
extended on this branch:

- native: for planar pages every band is read through
  `TIFFReadTile(..., sample)`/`TIFFReadScanline(..., sample)` and
  assembled into the same interleaved sample raster the contiguous
  lane produces, so band samples compare 1:1 with the production
  decoder's segment observer (which reports one band per segment,
  tagged with its plane index). Sixteen-bit samples compare at full
  precision including the low byte; zero tolerance;
- indices: on palette pages the native lane is the index raster
  (unpacked one byte per index for sub-byte depths) and the
  production segment observer supplies the same indices after codec
  and predictor;
- colormap: `TIFFGetField(TIFFTAG_COLORMAP, ...)` is dumped as
  `3 * 2^BitsPerSample` little-endian uint16 values per page and
  compared entry by entry against the decoder's parsed tables;
- rgba: `TIFFReadRGBAImageOriented(ORIENTATION_TOPLEFT)` as before.
  Planar RGB 16-bit keeps C03's single documented RGBA-lane
  difference (libtiff rounds, the native rule truncates);
  everything else in this contract must match exactly.

Pixels are compared as C03 RGB888 units with zero tolerance; a
rejection counts no samples. The comparator proves itself with
negative cases: a flipped low bit of a 16-bit planar sample (invisible
after `>> 8`) must diverge in the native lane, a flipped index bit and
a flipped ColorMap low bit must diverge in their lanes, and a missing
reference or failed reference command must diverge.

## Corpus

Tracked under `test/resources/tiff/planar-palette/` with SHA-256 and
origin in `test/resources/tiff/PROVENANCE.md`:

- independent files from libtiff's `pics-3.8.0` set (SGI/GraphicsMagick
  written): `flower-rgb-planar-08.tif`, `flower-rgb-planar-16.tif`,
  `flower-palette-02.tif`, `flower-palette-04.tif`,
  `flower-palette-08.tif`, `jello.tif`, plus the out-of-recorte
  rejections `flower-palette-16.tif`, `flower-rgb-planar-02.tif`,
  `flower-rgb-planar-04.tif`, `flower-separated-planar-08.tif`,
  `flower-separated-planar-16.tif`; the strip corpus keeps contributing
  `palette-1c-8b.tiff` (now compared) and the planar-alpha rejection
  `minisblack-2c-8b-alpha.tiff`;
- identified derivatives transcoded with libtiff 4.7.2 (`tiffcp -p
  separate` for planar, `tiffcp` for palette recode, and the extended
  `tiff_oracle_encode` for the 1-bit palette and explicit-tag layouts
  `tiffcp` cannot write): both byte orders, classic and BigTIFF,
  every codec of the matrix with valid predictors, edge tiles, single
  strips, orientations 1-4, and multi-IFD files mixing planar, palette,
  and contiguous pages.

## Commands

```sh
cc -O2 -o build/oracle/tiff_oracle_dump tool/reference/tiff_oracle_dump/tiff_oracle_dump.c \
  -I/opt/homebrew/include -L/opt/homebrew/lib -ltiff
python3 tool/tiff_planar_palette_reference.py --out build/evidence/D03
dart run tool/tiff_planar_palette_compare.dart --reference build/evidence/D03/reference.json \
  --out build/evidence/D03/compare
dart run tool/tiff_planar_palette_evidence.dart --out build/evidence/D03
dart run benchmark/tiff_planar_palette_benchmarks.dart --out build/evidence/D03/bench.json
```
