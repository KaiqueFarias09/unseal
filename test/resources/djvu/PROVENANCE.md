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
