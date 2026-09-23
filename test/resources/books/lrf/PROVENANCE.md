# LRF fixtures

The source HTML and 2×2 PNG in this directory were created for Unseal on
2026-09-23 and are dedicated to the public domain (CC0). `original.lrf` and
`illustrated.lrf` were generated from that source with
[Calibre 9.4.0](https://calibre-ebook.com/). Calibre's
[LRF reader](https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/lrf)
is used as an independent parsing oracle; no Calibre source code is included.

```sh
ebook-convert source.html original.lrf --title 'Unseal LRF Fixture' \
  --authors 'Unseal Test Team' --language en --level1-toc //h:h1
ebook-convert illustrated.html illustrated.lrf --title 'Illustrated Café Fixture' \
  --authors 'Unseal Test Team' --language en
lrf2lrs original.lrf --output original.lrs --dont-output-resources
lrf2lrs illustrated.lrf --output illustrated.lrs --dont-output-resources
```

The last two commands were used to compare expected pages, text, TOC, and
image references. Their temporary XML outputs are not test fixtures.

| File | SHA-256 |
| --- | --- |
| `source.html` | `a245cd90a4332b2b5d0d2d610967f7c1acdf5402b6306967944ce08b71f35f8f` |
| `illustrated.html` | `cb1fad078f6c163478f963435e22e323527a5f9fe224f27e356d18f8ded4f64d` |
| `swatch.png` | `886eca293713dd0dc77ee8c492c64e81359f6e0286b79d5f6df20c506466d1e2` |
| `original.lrf` | `cf5e5e973569e0c9c9d9dea159dfd8958b13160ed48be4b111f807f51caa7175` |
| `illustrated.lrf` | `4078e733625b5f4acb0b403ab05ac5fae766506dd2fe7a965cb997b2a26da2d9` |

These files test Calibre output, not the diversity of Sony Reader files from
other producers. A legally redistributable independent LRF corpus remains
needed before claiming broad legacy compatibility.

## Independent writer evaluation (excluded from the corpus)

Eruditio's LRF writer was evaluated at commit
[`c517504356fcf1ec68a72be5a5005dff393da3f8`](https://github.com/DevExzh/eruditio/tree/c517504356fcf1ec68a72be5a5005dff393da3f8).
That revision is licensed under
[Apache-2.0](https://github.com/DevExzh/eruditio/blob/c517504356fcf1ec68a72be5a5005dff393da3f8/LICENSE)
and contains an independent
[`LrfWriter`](https://github.com/DevExzh/eruditio/blob/c517504356fcf1ec68a72be5a5005dff393da3f8/crates/eruditio/src/formats/lrf/writer.rs).
It was built with:

```sh
cargo build --package eruditio --bin eruditio-convert \
  --no-default-features --features cli,native-fs
```

The CLI converted original CC0 HTML with title `Eruditio LRF Writer Fixture`,
author `Unseal Test Team`, language `en`, and `--no-transforms`. It exited
successfully, reported one chapter, and wrote an 873-byte output. The input
SHA-256 was
`c7c57a031156bf644511b9a856d87c82bc83f859cf3b026935f4047a71393822`; the
temporary output SHA-256 was
`44d8bb5698943c9d93e25dd7c913ad734b42723085fb1a34467a7ec9a7e64960`.
Neither file is included in the corpus.

The generated output is not interoperable. Unseal rejects it with the typed
error `LRF page tree is missing`. Calibre 9.4.0's `lrf2lrs` independently
rejects it with `Unknown tag in BookAttr: Tag F503 *Link`; the same Calibre
command successfully decompiles `original.lrf`. In the pinned Eruditio writer,
`BookAttr` is given a generic `F503` Link tag for the page tree. Calibre's
[`BookAttr` definition](https://github.com/kovidgoyal/calibre/blob/55e3f7667ee04a52addee24a38c91b98b28a55d1/src/calibre/ebooks/lrf/objects.py#L1163)
uses the dedicated `F57B` ChildPageTree field instead, and its
[LRF writer](https://github.com/kovidgoyal/calibre/blob/55e3f7667ee04a52addee24a38c91b98b28a55d1/src/calibre/ebooks/lrf/pylrs/pylrf.py#L312)
defines that tag separately. This makes the output unsuitable as a valid
cross-producer fixture. The Eruditio writer also fixes its output version at
1000; it exposes no option to emit an older header version.

At the same Eruditio commit, `test-data/real-world` contains no `.lrf` file or
LRF provenance manifest. The independent output is therefore recorded as a
failed compatibility experiment, not as evidence of supported LRF variants.

The legacy-version regression tests build in-memory variants of
`original.lrf`: they remove the five-byte version-801+ header tail at offsets
`0x53..0x57`, move the metadata stream to the legacy `0x53` position, update
the object-index offset and object offsets, then set versions 1, 799, and 800.
These are synthetic layout cases, not independently authored LRF books, and
they are not included as binary fixtures.

An independent candidate is Yosemite's [*Steep Trails* page](https://www.yosemite.ca.us/john_muir_writings/steep_trails/) and linked
[Sony LRF file](https://www.yosemite.ca.us/john_muir_writings/steep_trails/steep_trails.lrf).
The page says the text derives from Project Gutenberg Etext #326, but it does
not state a license for the LRF package itself. The browser refused access to
the linked binary during fixture research. Neither the source text's public
domain status nor the page's availability establishes redistribution rights
for this generated file, so it is not vendored.

LRX research uses Sony's support article, which classifies ordinary BBeB as
unsecured text and BBeB Book (Marlin) as DRM text, and Sony's 2004 release,
which describes OpenMG rights protection for BBeB. LRX2 test bytes are built
synthetically around the existing CC0 LRF fixture to verify plaintext
metadata access and typed DRM rejection; no protected book content is present.
