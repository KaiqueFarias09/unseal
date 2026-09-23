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

Two real DjVu files are retained to test recognition and honest rejection of
image codecs that are not yet decoded:

| File | Source and rights | SHA-256 | Image codec |
| --- | --- | --- | --- |
| `cable-1973.djvu` | [US State Department cable](https://archive.org/details/State-Dept-cable-1973-100133), downloaded from the [djvu-rs public-domain corpus](https://github.com/matyushkin/djvu-rs/blob/main/tests/corpus/cable_1973_100133.djvu). US federal-government work. | `ceaac0b3bf8b4ea665c09e26a6f00d5d1e95b00757a7d2b9613948f16610d96b` | JB2 |
| `big-scanned-page.djvu` | [djvu.js test asset](https://github.com/RussCoder/djvujs/tree/master/library/assets), downloaded via the [djvu-rs test fixture](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/big-scanned-page.djvu). The [attribution record](https://github.com/matyushkin/djvu-rs/blob/main/tests/fixtures/ATTRIBUTION.md) identifies test assets as Unlicense. | `200f9bcaf891f12014fe39bd9e119f1f4560566abd8bea9b67a21eb198567594` | IW44 |

Both downloads were made on 2026-09-23. The tests assert their metadata is
recognized and full opening reports `DjvuUnsupportedCodecException`; they are
not presented as visually supported pages.
