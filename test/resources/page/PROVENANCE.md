# PAGE XML test fixtures

Real PAGE 2019-07-15 ground-truth sidecars from the OCR-D
`gt_structure_text` corpus (https://github.com/OCR-D/gt_structure_text,
retrieved 2026-10-17), licensed CC-BY-SA-4.0 — the corpus `LICENSE.md`
records the license and the `METADATA.yml` records authorship and
provenance. The sidecars were produced in Aletheia over scans of the
Deutsches Textarchiv prints (1506–1897, German and Latin, including
Fraktur long-s and combining marks). The target images travel with the
mission corpus in the C02 workspace (`build/c02/corpus/`, SHA-256
pinned); they are not committed because of their size.

- `kant-aufklaerung-1784-0017.xml` — Kant, "Beantwortung der Frage:
  Was ist Aufklärung?", page 17. Full region/line/word granularity,
  baselines, reading order with indexed region refs, German/Latin
  languages. SHA-256
  `4a92747331018bdb11244a44854778b59757ed10c39913fa5bad67bf08f937cc`.
- `petrarca-psalmi-1506-0016.xml` — Petrarca, Psalmi poenitentiales,
  page 16 (1506, Latin). Region/line/word with baselines. SHA-256
  `cce1e5631350f7eac1558f07d164dc267685a9618c6e3893c889cb7fea59a43d`.
- `clauren-mimil-1815-0023.xml` — Clauren, "Mimi und ihr Bruder",
  page 23 (1815). Line-level granularity: text lives on TextLine
  TextEquivs, lines carry no Word children. SHA-256
  `8062fcd32e9b29da116e8b94093ce55d009454ed78570c8f6b72c00239e4b003`.
- `hilbert-zahlkoerper-1897-0370.xml` — Hilbert, Zahlkörper report,
  page 370 (1897). Structure-only page: regions with polygons but no
  TextLine children, and TextEquiv elements whose Unicode content is
  empty — a real producer shape the subset accepts as data. SHA-256
  `c84a13f642c33cee3eac2fce5c2ea0f3491a7add4583ef6ca78a505e713f5d09`.
- `kant-0017-derived-alternatives.xml` — DERIVED, not source data: a
  mutated copy of the Kant page that adds the attributes the corpus
  itself lacks (region and page `orientation`, a lower-index TextEquiv
  alternative with `conf`, TextEquiv and baseline confidences, PPI
  resolution) so the subset's optional-attribute coverage is testable
  against a real structure. SHA-256
  `da5a9e759b85650f33549a6d59ac50f05b5e3f62fe4a4a1999561941d24f4e50`.

All five validate against the pinned official schema
`pagecontent-2019-07-15.xsd` (SHA-256
`5d7da5af5f5e06d3b9cd1e78b407ffca1862f78ad9823ed89c302fb6409932d5`)
with lxml 6.1.1 / libxml2 in the C02 reference lane; that lane and its
negative corpus re-run in the C02 oracle gate. Negative documents used
by the tests are inline strings, clearly synthetic, and derive from no
fixture.
