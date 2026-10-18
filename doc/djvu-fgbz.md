# DjVu FGbz foreground colors

Unseal decodes `FGbz` chunks and applies the correct color to every JB2 blit.
This file fixes the comparison contract for that support: corpus, units,
normalization, tolerances, refusals, extensions, and budgets. The oracle is
DjVuLibre 3.5.29 executed on this host.

## What FGbz is

The DjVu 3 specification (§8.3.10) defines `FGbz` as the foreground color
chunk of a compound page:

- version byte: bit 7 declares per-blit color data; bits 0–6 are the version,
  currently 0;
- `INT16` palette count, then that many 3-byte entries **in B, G, R order**;
- with bit 7 set: an `INT24` blit count followed by BZZ-compressed `INT16`
  color indices, one per `Sjbz` blit in decode order ("Index0 is the color of
  JB2 blit 0").

The native decoder is `DjVuPalette::decode` (DjVuLibre `libdjvu/DjVuPalette.cpp`);
the native renderer colors blits in `DjVuImage::stencil`'s two-layer branch
(`libdjvu/DjVuImage.cpp`). A page's `get_fgbc` lookup also walks `INCL`
includes, so a shared component may carry the page's FGbz.

## Corpus

| File | Producer and rights | FGbz content |
| --- | --- | --- |
| `test/resources/djvu/navm-fgbz.djvu` | djvu.js/djvu-rs fixture `navm_fgbz.djvu`, Unlicense (see `test/resources/djvu/PROVENANCE.md`) | 6 pages, palettes of 2/7/5/25/47/8 colors, one shared Djbz through INCL, hundreds of overlapping blits per page |
| `test/resources/djvu/spec-bundled.djvu` | djvu.js/djvu-rs fixture `DjVu3Spec_bundled.djvu` (the official DjVu 3 specification document), Unlicense per the djvu.js attribution record | 13 FGbz pages, palettes up to 157 colors, five Djbz dictionaries (one inline, four shared) |
| derived fixtures under `test/resources/djvu/derived/` (see `tool/djvu_fgbz_fixtures.py`) | generated locally with the pinned DjVuLibre 3.5.29 producer tools (`cjb2`, `c44`, `bzz`, `djvuextract`, `djvumake`); inputs are locally drawn PBM/PPM cards, no third-party content | overlap cards, repeated-symbol multi-color cards, the color-group ordering card, a shifted-blit pair, a palette-only chunk, a palette-without-indices chunk |

Additional real FGbz producers: the searched hosts do not offer one under a
clean license. Internet Archive's Google-era scans (`*-goog` derivatives) use
`FG44` color layers, never `FGbz`; the Delpher and Polona items expose no
`.djvu` derivatives. The two real corpus documents stay the real-file
evidence; the derived fixtures cover the structural cases they lack.

## Units and normalization

- Palette colors are 8-bit RGB triples in comparisons. The bytes on disk are
  B,G,R per the spec; both sides convert before comparing. RGB in JSON
  evidence is `r, g, b`.
- Blits compare as the native `JB2Blit` quadruple `(left, bottom, shapeno, w,
  h)`: bottom-left pixel coordinates, the combined shared-plus-local shape
  index, the shape bitmap's stored dimensions, native shape number and exact packed bitmap bytes. `shapeno` indexes the
  combined dictionary, matching the Dart decoder's symbol list.
- Color indices compare as the raw `colordata` list — one entry per Sjbz
  blit, in decode order.
- Rasters compare top-down. PPM lanes use native pixel dimensions.

## Comparison lanes

Three lanes, all lossless (zero tolerance):

1. **Colors, indices, blits.** `tool/djvu_fgbz_oracle.cpp`, linked against the
   pinned DjVuLibre 3.5.29 build, dumps per page: INFO geometry, the native
   blit list, the palette as RGB, and `colordata`. The Dart decode produces
   the same lists; the comparator `tool/djvu_fgbz_compare.dart` diffs them
   exactly, including count equality between colordata and blits.
2. **Native foreground raster.** `ddjvu -mode=foreground -format=ppm` at
   native scale. ddjvu fixes the target gamma at 2.2 and white at
   `255,255,255` (ddjvuapi default; the CLI exposes no override), so on the
   corpus's `gamma=2.2` pages the library's correction is the identity and
   palette colors pass through unchanged. Unseal renders the same contract —
   white paper, each ink pixel in its blit's palette color — as a 24-bit
   raster, and the comparator diffs byte-exact. Paint order is the native
   two-layer group order: repeatedly take the first remaining blit, gather
   the forward run whose `left` never regresses, paint the gathered blits of
   the leader's color; the last pass to touch a pixel wins. A pass whose
   leader sits left of x=0 would spin in the native loop; Unseal paints that
   leader and continues (the native behavior is a hang, so no raster exists
   to match).
3. **Composed page image.** The house hard-mask contract of the base:
   background pixels come from BG44/BGjp, ink pixels take the blit's palette
   color where FGbz provides one and stay black otherwise. Compared by
   pinned raster hashes and point assertions in the DjVu tests. This lane is
   deliberately separate from ddjvu's blended stencil, whose deviation stays
   the one documented in the base tests.

Pages whose INFO gamma differs from 2.2 keep lanes 1 and 3 exactly; lane 2
then diverges by ddjvu's `target/info` gamma correction, which Unseal does
not reproduce. All corpus FGbz pages carry gamma 2.2, so lane 2 compares every FGbz page, plus the first page of every document as a black-ink control. Other pages without FGbz are compared in lane 1 and covered by the inherited corpus tests; their rasters are not part of the colored foreground lane. Every derived fixture is upright (orientation
flag 1); rotation stays a display concern under the base contract.

## Acceptance and defaults

- A page without `FGbz`, a `FGbz` without color data (version byte 0x00 —
  palette only), and an FGbz on a page without `Sjbz` render exactly as the
  base: black ink. The native foreground mode agrees by construction —
  `DjVuImage::stencil` refuses a colored render when `colordata` is empty or
  its count mismatches, and ddjvu falls back to the bilevel mask.
- A version byte with bit 7 set makes `colordata` authoritative: its length
  must equal the Sjbz blit count, every index must be smaller than the
  palette size.

## Refusals (typed, before allocation)

All are `DjvuException` unless noted:

- version bits 0–6 other than 0 (native `bad_version`);
- palette or color data truncated against the declared counts;
- an index outside `0 .. paletteSize-1` (native `bad_palette`);
- `colordata` length different from the Sjbz blit count when bit 7 is set;
- two `FGbz` chunks on one page (native duplicate-foreground check);
- color indices declaring more entries than the 65536 JB2 record budget, or
  a color-data BZZ stream that produces trailing blocks beyond the declared
  count — native tolerates such trailing data; Unseal refuses it like every
  other strict-bounds layer;
- `FGbz` beside `FG44`/`FGjp`/`FG2k` on the same page:
  `DjvuUnsupportedCodecException`, mirroring DjVuFile's
  duplicate-foreground refusal. FGjp/Smmr/FG2k stay unsupported as before.

## Budgets

| Budget | Cap | Charged |
| --- | --- | --- |
| Palette | 65,535 entries (192 KiB) | entry bytes before allocation |
| Color indices | 65,536 typed Uint16 entries (128 KiB of BZZ output) | book ledger reserves 9× maximum BZZ bytes plus 8 KiB fixed work before decoding; block sizes checked before allocation |
| Color map and temporary mask | one page-sized `Uint16List` plus temporary bilevel `Uint8List` (3 bytes per pixel) | page pixels + bytes reserved before allocation |
| Page-local auxiliary state | 8 MiB per colored page, plus 64 bytes per context node and twice the decoded local symbol pixel count | book ledger before allocation; the extra symbol reservation includes cropped storage |
| Recolor work | the JB2 blit-pixel budget, charged once more for the color pass, plus a 64M-step cap on the group scan | typed refusal beyond |
| Output raster | the existing book-level decoded-pixel and 1 GiB raster-byte budgets | the 24-bit BMP (or composed BMP) bytes before allocation |

The recolor pass touches each symbol's ink pixels only; no whole-page buffer
per color or per blit is allocated at any point.

## Wire and sessions

The composed images carry the colors, so the existing wire codec and worker
need no change: the browser main thread receives colored page images as
blobs, text/zones/search/navigation are untouched, and two worker opens
cannot share color state because no color state exists outside the page
parse. VM and Chrome decodes are byte-identical by construction and compared
by the Chrome suite.

## Out of scope

Stencil/alpha blending as ddjvu's color mode performs it (the house
hard-mask contract stays), `FGjp`/`Smmr`/`FG2k`, chained shared dictionaries,
an FGbz on a shared component consumed through INCL (the native lookup
supports it; no available corpus or producer exercises it, so it stays
unimplemented rather than untested), UI rendering in Grimoire, and
DjVu editing or export.

## Reproduction and acceptance matrix

Set `DART_BIN` to the pinned Dart SDK and `DJVU_SOURCE` to the official
DjVuLibre 3.5.29 source tree (including config.h); the runtime library must
also be 3.5.29. Run `python3 tool/djvu_fgbz_evidence.py reference`, then
`python3 tool/djvu_fgbz_evidence.py compare`. No native dependency ships in
the package. The reference JSON records the actual library version, palette,
indices, native shape IDs and packed symbol bitmaps. Every required FGbz
foreground PPM must exist. Empty/duplicate/incomplete page lists fail.

| IDs | Evidence produced by the driver |
| --- | --- |
| DC01 | Public bundled/indirect/defaults tests in `djvu_fgbz_test.dart` |
| DC02 | Native helper, djvudump/djvused, real spec and navm files plus identified derivatives |
| DC03 | Exact shape number, bitmap, position and palette-index comparisons; overlap and repeat cards |
| DC04 | Every FGbz foreground PPM byte-exact; inherited composite hashes and pixel assertions kept separately |
| DC05 | Typed malformed-version, palette, index, count and duplicate foreground tests |
| DC06 | Per-page caps, cumulative-budget adversarial test and before-allocation accounting |
| DC07 | Fresh compiled worker: FGbz/TXTz, search, zones, anchor identity, navigation, distinct opens and signed IW44 parity |
| DC08 | Mutated palette/index/blit/bitmap, missing JSON/PPM, empty reference and native nonzero negatives; timed VM suite with peak RSS |

The BZZ block declaration includes its terminating marker: N declared bytes
produce N−1 decoded bytes. The output limit therefore checks N−1; the previous
condition rejected exact-size native FGbz index streams. The IW44 changes
normalize signed right-shift results on dart2js; the small gradient background
card pins the complete VM/Chrome composite hash, rather than testing only
white samples. The original corpus fixtures remain byte-identical.
