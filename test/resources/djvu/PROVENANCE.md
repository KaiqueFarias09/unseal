# DjVu fixture provenance

`../books/djvu/jpeg-only.djvu` is generated locally by `tool/generate_djvu_fixture.dart`
from the repository's generated grayscale `tiny.jpg`. It has one 8 × 8 page,
an INFO chunk, a direct JPEG BGjp image, and uncompressed TXTa text. No
downloaded book or third-party copyrighted page is included. Regenerate with
`dart run tool/generate_djvu_fixture.dart`; verify with the `--check` flag.

The builder follows the [DjVu 3 file format specification](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf),
sections 8.1, 8.2, 8.3.11, 8.3.13, and 8.3.5. It is a narrow synthetic test
and is not evidence of interoperability with arbitrary DjVu authoring tools.
The multipage test uses an in-memory structural bundle; it does not certify
compressed DIRM name decoding or external indirect documents.

Real DjVu files are retained as format fixtures. The first page's Sjbz chunk
from `cable-1973.djvu` is also isolated in memory for the JB2 decoder test; the
source bytes are not modified. The decoder composes its grayscale BG44 layer
with that mask. Its unmodified source page is still tested as a real container.
The large scan remains a budget-rejection case:

| File | Source and rights | SHA-256 | Image codec |
| --- | --- | --- | --- |
| `cable-1973.djvu` | [US State Department cable](https://archive.org/details/State-Dept-cable-1973-100133), downloaded from the [djvu-rs public-domain corpus](https://github.com/matyushkin/djvu-rs/blob/main/tests/corpus/cable_1973_100133.djvu). U.S. federal-government work, public domain under [17 U.S.C. § 105](https://www.govinfo.gov/about/policies). | `ceaac0b3bf8b4ea665c09e26a6f00d5d1e95b00757a7d2b9613948f16610d96b` | JB2 + grayscale BG44 |
| `big-scanned-page.djvu` | [djvu.js test asset](https://github.com/RussCoder/djvujs/tree/master/library/assets), downloaded via the [djvu-rs test fixture](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/big-scanned-page.djvu). The [attribution record](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/ATTRIBUTION.md) identifies test assets as Unlicense. | `200f9bcaf891f12014fe39bd9e119f1f4560566abd8bea9b67a21eb198567594` | IW44 |
| `boy-iw44.djvu` | [djvu.js boy asset](https://github.com/RussCoder/djvujs/blob/master/library/assets/boy.djvu), copied from `library/assets`; the repository [license](https://github.com/RussCoder/djvujs/blob/master/LICENSE.md) places everything outside `library/src` under The Unlicense. | `8cde44879f3b961d0f3f317500fbfbf8a8f4fd07e030f39b04a0a472e5c17982` | Grayscale BG44, 192 × 256 |
| `chicken-iw44.djvu` | [djvu.js chicken asset](https://github.com/RussCoder/djvujs/blob/master/library/assets/chicken.djvu), copied from `library/assets`; the repository [license](https://github.com/RussCoder/djvujs/blob/master/LICENSE.md) places everything outside `library/src` under The Unlicense. | `4e0a0370e63776198dbfb32a191248fafe258d35b4d09758a6e0fabd513d2ad3` | Progressive color BG44, 181 × 240 |
| `happy-birthday-iw44.djvu` | [djvu.js happy birthday asset](https://github.com/RussCoder/djvujs/blob/master/library/assets/happy_birthday.djvu), copied from `library/assets`; the repository [license](https://github.com/RussCoder/djvujs/blob/master/LICENSE.md) places everything outside `library/src` under The Unlicense. | `cf56fb65a5c38d566f72e62032fffd07dabc361d01a03d642c423619ffc340cd` | BG44 + Sjbz + FG44, 475 × 400 |

The downloaded files were verified on 2026-09-23 against the listed SHA-256
values. The temporary upstream `chicken.png` reference has SHA-256
`832326f29e344dbc3446a2df6e66b8bcf7fd4ba0001fdc1ff8469046056e9838`; its
43,440 decoded RGB pixels match the output exactly, whose raster SHA-256 is
`5b7623de3a100f2d4e340d03e269e37547184fe2cae581609b471ed1ee92b6d9`. The
temporary upstream `boy.png` reference has SHA-256
`5ec1f4772e5c5a61df7d37b71298e5f16879c4ed74ebd1b192a73e0aa3ba10d2`; all
49,152 decoded RGB pixels match exactly, with raster SHA-256
`a237ff54ff7bd43cd3096b0333ede3ce681c53f5635f8a642be12e5946f77717`. The
temporary `happy_birthday.png` reference has SHA-256
`d2f9c01867744c11a2f98dbebe57974b4ed2b192e2ddfab079c999036562b1e`. Against
it, the composed 475 × 400 RGB image has mean absolute channel error 0.8024,
maximum channel error 33, and 82,227 of 190,000 exact pixels; all 25 grid
samples are within three levels per channel. The output RGB hash is
`150361d6f59cac4bbdca0c34d7f3d1e1989b652e8ead3e8b3643bf80552d78ad`.
These PNGs are upstream assets under the same Unlicense and are intentionally
not checked into the corpus.

The JB2 specification numbers rows from the bottom of the page (§§11.2.4,
11.2.5), whereas the decoded mask is stored top-down. The decoder converts a
symbol's bottom-origin placement when blitting it, without flipping the rows
inside the glyph. This keeps foreground placement aligned with the continuous
tone layers. The boy grayscale page is covered by its full-raster hash against
the upstream PNG reference and assertions that every pixel has equal RGB
channels.

The decoder follows the [DjVu 3 specification](https://www.sndjvu.org/spec.html).
The IW44 bucket contexts, inverse transform, and ZP state tables were
cross-checked against the independent
[djvu-rs implementation](https://github.com/matyushkin/djvu-rs), licensed under
MIT; its notice is included in `licenses/djvu-rs-MIT.txt`. No DjVuLibre GPL
implementation source was copied.

## Scanned-archive corpus (added 2026-09-30)

The six real scanned-book documents below exercise the
[supported DjVu contract](../../../README.md#supported-formats).
Every file was verified on 2026-09-30 by re-downloading from the listed URL
and comparing SHA-256 byte-for-byte. The table records each tracked file's
feature set. Historical stress-corpus counts remain in Git history; pending
compatibility work is collected in the [roadmap](../../../doc/roadmap.md).

| File | Source and rights | SHA-256 | Feature set (djvudump 3.5.29) |
| --- | --- | --- | --- |
| `cyrillic.djvu` | [djvu-rs corpus `cyrillic_simonovich_co2.djvu`](https://github.com/matyushkin/djvu-rs/blob/main/tests/corpus/cyrillic_simonovich_co2.djvu), from [Симонович 1905 on archive.org](https://archive.org/details/20200630_simonovich_uglekislota). The [corpus README](https://github.com/matyushkin/djvu-rs/blob/main/tests/corpus/README.md) states: "Public domain DjVu files used for benchmarks and integration tests. All files are in the public domain in the United States and most other jurisdictions, either because they were published before 1928 or because they are US government works." | `596258ef4c283fc33be1e0f77a5778378a5a95220b09776d0fdd05d1744d14ad` | Bundled, 12 pages; 1 Djbz in a DJVI form; every page INFO + INCL + Sjbz + TXTz; no background layer |
| `spec-bundled.djvu` | [djvu-rs fixture `DjVu3Spec_bundled.djvu`](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/DjVu3Spec_bundled.djvu). The fixtures [ATTRIBUTION record](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/ATTRIBUTION.md) states: "These test assets fall under [The Unlicense](https://unlicense.org/) as per the djvu.js license terms (the GPL v2 applies only to library source code in `library/src`, everything else is Unlicense)." | `2f5e8995c86902daf2038fa8833b6e0dec63cf5aac69202f6b5cd349f1bc6bbc` | Bundled, 71 pages (85 files); NAVM; 10 THUM forms with 71 TH44; 5 Djbz (one inline in page 1, four in DJVI forms) + 70 INCL; 71× INFO/Sjbz/TXTz/CIDa/ANTz; 13 FGbz; 33 BG44 |
| `navm-fgbz.djvu` | [djvu-rs fixture `navm_fgbz.djvu`](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/navm_fgbz.djvu). Unlicense per the same [ATTRIBUTION record](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/ATTRIBUTION.md). | `aec189aa8a165580a87725f291e0da5ba9a16e25295b4e1e4aea162115d2d084` | Bundled, 6 pages; NAVM; 1 Djbz + 6 INCL; 6 FGbz; 1 ANTz; 12 BG44; 6 Sjbz; no text layer |
| `links.djvu` | [djvu-rs fixture `links.djvu`](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/links.djvu). Unlicense per the same [ATTRIBUTION record](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/ATTRIBUTION.md). | `3d7740439e20ae48366f62740a64f9ab67fb2062a6a7afb726e30dee81e4403f` | Minimal bundled, 1 page; NAVM; INFO + Sjbz only; no background, no text |
| `goody-twoshoes.djvu` | [djvu-rs corpus `goody_twoshoes.djvu`](https://github.com/matyushkin/djvu-rs/blob/main/tests/corpus/goody_twoshoes.djvu), from [*Goody Two-Shoes* 1888 on archive.org](https://archive.org/details/goodytwoshoes00newyiala) ("1888, NOT_IN_COPYRIGHT" per the [corpus README](https://github.com/matyushkin/djvu-rs/blob/main/tests/corpus/README.md); pre-1928 US public domain). | `20b594d3207d07b98b8ef0f8b6cd8744e94942575e71916cdac8684f5b5eeb97` | Bundled, 16 pages; production Google/IA pipeline: 16× INFO/Sjbz/CIDa, 64 BG44, 16 FG44, 9 TXTz |
| `speller-1921.djvu` | [*The test and study speller* (Starch & Mirick, 1921)](https://archive.org/details/testandstudyspe06mirigoog), downloaded from [the item's DjVu derivative](https://archive.org/download/testandstudyspe06mirigoog/testandstudyspe06mirigoog.djvu). Published 1921 (pre-1928 US public domain); the [item metadata](https://archive.org/metadata/testandstudyspe06mirigoog) records `possible-copyright-status: NOT_IN_COPYRIGHT`, scanned by Google / contributed by Harvard University. | `4049d398289d2c79debc9dd8a3365457d0d09a936e843ecc48cd6ef55f922025` | Bundled, 121 pages; 115 TXTz, 119 Sjbz, 20 BG44, 3 FG44, CIDa on every page |

The two larger stress files stay out of git by design (≤ ~4 MB corpus budget)
and live in `/Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/`:
`pathogenic_bacteria_1896.djvu` (djvu-rs corpus, *Pathogenic Bacteria* 1896,
pre-1928 US public domain; SHA-256
`f0af59e077811f365a7c256003571dc1de4dd534a1e35268322f7a80afe7a1aa`; 520 pages,
52 Djbz, 513 INCL) and `hawthornescount00clargoog.djvu` (archive.org
NOT_IN_COPYRIGHT Google scan; SHA-256
`6030287b44611afe7a223438373052aaac6815f9976955e1933a0c621423a27c`; 449
pages). Their provenance README, the independent djvulibre references, and the
derived indirect bundle from `cyrillic.djvu` also live in that directory.

Independent-reference oracles (djvulibre 3.5.29, out of git, in
`/Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/references/` with
`references.sha256`): one `djvutxt <file> <out>` plain-text extraction per
corpus file (this build has no `-out=text` flag; the positional default mode
is the plain-text output) and `ddjvu -format=ppm -page=N <file> <out>` renders
for pages 1, middle, and last of each file (this build offers
pbm/pgm/ppm/pnm/rle/tiff/pdf, no bmp; PPM is the uncompressed raster). The
invocations and hashes:

| File | Text SHA-256 | Render SHA-256 (page 1 / middle / last) |
| --- | --- | --- |
| `cyrillic.djvu` | `fd9b8b0fd9d025e6720c0591dc5e8b7c495189a4eb47d23b11c8a4501814609f` | `e2e119d9…cae22` (p1) / `85453bce…fdb9fe` (p6) / `f14fd7a4…630145` (p12) |
| `spec-bundled.djvu` | `6f59cb00d6fc55dd5b1271185643b8367b6785e6f08347a34779b34db9a4e041` | `99fc103a…a1855` (p1) / `7d152dbc…65729` (p36) / `096ed0a9…49d7a` (p71) |
| `navm-fgbz.djvu` | empty — no text layer (no TXTz chunk) | `2b8d42ed…7650b9` (p1) / `59ebde71…719544` (p3) / `e80ee296…e872b` (p6) |
| `links.djvu` | empty — no text layer (no TXTz chunk) | `25abee96…4a683b` (p1) |
| `goody-twoshoes.djvu` | `781e428d01a88dd48b28eb7f85bd9ca09da4501569c522d3359a8187c2bcc309` | `9061c101…e83ef` (p1) / `d86d9450…189cdc` (p8) / `27e80acf…d5e2e` (p16) |
| `speller-1921.djvu` | `2ad2490a2bf62def0623dbeb3edba72412b31baaf735bd8164f5a35aa5bcf072` | `fff8ec8b…0208d5` (p1) / `df81dc3a…90575d` (p61) / `b8d2ea26…191ba7d` (p121) |

(The render hashes are abbreviated here to keep this file readable; the full
64-hex-digit values are canonical in that directory's `references.sha256`.)
The derived INDIRECT bundle built from `cyrillic.djvu` renders all 12 pages
byte-identically to the bundled original with
`djvmcvt -i <in> <dir> <idx>`; see
`/Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/derived/README.md`.

## Derived indirect bundle (added 2026-09-30)

`derived/` holds the tracked INDIRECT DjVu document used by the file-based
open path. It was derived locally with djvulibre 3.5.29 from the in-git
`cyrillic.djvu` (same rights: pre-1928 US public domain): `djvm -d` pruned
the document to page 1 plus its shared dictionary, then
`djvmcvt -i one.djvu <dir> index.djvu` split it into an indirect directory.
No component byte was rewritten — the page and dictionary FORMs are verbatim
copies of the bundled original's components, and `ddjvu -format=ppm -page=1`
renders of the indirect directory and the pruned bundled document are
byte-identical.

| File | Role | SHA-256 |
| --- | --- | --- |
| `derived/cyrillic-page1-index.djvu` | Indirect index (DIRM, 2 files, 1 page) | `a38a5cbc332b21993bbaa0293065ec0dfe7b3f853886e1dd4b7e4a16f56ff8a7` |
| `derived/00001.djvu` | Page component (verbatim from `cyrillic.djvu`) | `5cdf26087eadcbacec269ccbeae5fc5988c4741ad4eb8c4a1267a646925b9d67` |
| `derived/00012.djbz` | Shared JB2 dictionary component (verbatim) | `e2d34aa415cc6ae174bb31dd6f6be78ee8c13f59e6b8192f38ab6c4534833b73` |

The full 12-page indirect derivation (13 components) stays out of git at
`/Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/derived/` with its
own hashes and djvudump record. `parseDjvuBook` keeps rejecting indirect
directories over bytes with `DjvuUnsupportedCodecException`; only the
file-based open path resolves sibling components.
