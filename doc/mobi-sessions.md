# MOBI/AZW3 progressive sessions (B04)

This document records the frozen comparison policy for the B04 mission
(sessões progressivas MOBI/AZW3), fixed before any session
implementation was written, plus the delivered feature's behavior and
limits. The git history pins the order: this policy landed before the
first session commit.

## Reference oracle

| Property | Value |
| --- | --- |
| Programs | `ebook-convert` and `calibre-debug` from the same Calibre installation |
| Installed version | 9.4.0 (frozen macOS bundle; the bundle embeds no git revision — `calibre.constants.git_version` is `None`) |
| Source revision | calibre tag `v9.4.0` (tag object `55e3f7667ee04a52addee24a38c91b98b28a55d1`) → commit `0fe2747ab1959e715a239a7fe81eaa85692eb004` |
| Installed and source recorded separately | yes, as required; the binary version and the upstream source commit are independent facts |

Calibre is the independent comparator for content. It is never a
runtime dependency: the library ships no conversion path and the
session path never shells out.

## Evidence species

Per the campaign protocol, three species of evidence are kept apart:

1. **Executable oracle** — Calibre reads the same input bytes and
   produces an OEB tree; `tool/mobi_session_compare.dart` parses that
   tree through the same canonical text scanner Unseal uses and
   compares. A missing program, an empty output, or a failed run fails
   the gate; a format refusal by Calibre would be recorded as such.
2. **Normative contract** — the MOBI format rules the eager parser
   already implements (PalmDB record table, MOBI/EXTH headers, DRM
   rejection, PalmDOC/HUFF-CDIC/stored compression, KF8 FDST/skeleton/
   fragment reconstruction). Session output must satisfy the same
   contract, exercised by the existing eager test suites and the new
   session tests.
3. **Operational property** — progressivity: what the open pass read,
   decoded and materialized, measured by engine counters and verified
   against analytically derived expectations (which records cover a
   section). Content parity never proves progressivity; the counters
   are a separate report section.

## Frozen comparison rules

Declared before implementation. `tool/mobi_session_compare.dart`
implements them; changing a rule invalidates prior evidence and
requires a new dated declaration in this file.

Integration review, October 17, 2026: R5 now additionally requires independent
Calibre metadata, navigation and original resource comparisons, and R6 uses
fresh processes for the memory baseline. Earlier text-only or same-process
reports do not establish these additional checks; rerun the current driver.

- **R1 canonical text (eager ↔ session).** Text space is
  `documentTextOf` (the shared canonical scanner). MOBI6: the
  concatenation of session section texts, in reading order, joined by
  `\n`, equals the eager `index.html` text. KF8: session part texts
  equal eager part texts one-to-one under the same names.
- **R2 resources.** Every resource path the eager parse holds (images,
  fonts) loads through the session with byte-identical SHA-256, and
  the path sets are equal.
- **R3 navigation.** Labels are equal in sequence. MOBI6 targets have
  one declared, expected difference: eager emits same-document anchors
  (`#fileposN`), the session emits section-qualified anchors
  (`chapterNNNNN.html#fileposN`), because the session reading model
  has one file per section. Acceptance: every session target resolves
  — the section exists in the reading order and the anchor id survives
  in the section source. KF8 targets are equal strings.
- **R4 metadata.** Title, authors, languages, and identifiers equal.
- **R5 Calibre text normalization.** Both sides pass through the same
  canonical document-text scanner, file pieces join with `\n`, then
  ASCII whitespace **and Unicode space separators** (`U+00A0`,
  `U+1680`, `U+2000`–`U+200A`, `U+2028`, `U+2029`, `U+202F`,
  `U+205F`, `U+3000`, `U+FEFF`) collapse to single spaces and the
  result trims. The Unicode separators are included because the
  calibration runs (below) show Calibre preserving a `U+00A0` the
  eager pipeline drops — a spacing reconstruction difference, not a
  content difference. Pass rule: exact equality after normalization.
  The acceptance run requires both Calibre directories. It also compares
  OPF title/authors/languages and source ASIN, NCX label order/depth and
  resolved target text, plus exact image/font hash multisets from Calibre
  extraction before conversion. `tool/mobi_calibre_resources.py` runs
  inside Calibre to avoid treating its cover resizing or omitted thumbnail
  as differences in the source resource bytes.
- **R6 progressivity instrumentation.** The engine counts PDB record
  reads, text records decompressed, decompressed bytes, text bytes
  materialized, and resource bytes materialized. Required properties:
  after open, zero section text and zero resource bytes are
  materialized; loading one section decompresses exactly the records
  its byte span covers (cross-checked against the record offset index
  the open pass built). The baseline measurement runs eager and
  session over the same file in the same execution mode and reports
  wall time, sampled current RSS, and process peak RSS (VM). Each eager
  and session measurement runs in its own fresh VM process; PIDs and
  per-stage metrics are recorded. These are process measurements including
  runtime overhead, not estimates of retained book objects.

### Calibration evidence (pre-implementation)

Run at base `3facb20` with the eager parser only, before any session
code existed, using `build/inputs/` copies (hashes in
`build/evidence/b04/initial-reference.json`):

| Fixture | Calibre exit | Result under R5 |
| --- | --- | --- |
| `alice-old-pg.mobi` (MOBI6, PalmDOC) | 0 | exact equality (163,069 normalized characters) |
| `alice-kf8-pg.azw3` (KF8, PalmDOC) | 0 | exact equality (162,690 normalized characters) |
| `alice-joint.mobi` (joint MOBI6+KF8) | — | eager fingerprint recorded (Calibre leg optional for this input) |

## Corpus matrix

| Fixture | Origin | Covers |
| --- | --- | --- |
| `test/resources/books/mobi/alice-old-pg.mobi` | Project Gutenberg (licensed corpus) | MOBI 6, PalmDOC, UTF-8, images, TOC anchors |
| `test/resources/books/mobi/alice-kf8-pg.azw3` | Project Gutenberg (licensed corpus) | KF8/AZW3, PalmDOC, FDST/skeleton/fragment reconstruction, CSS, fonts, images, NCX |
| `test/resources/mobi/alice-joint.mobi` | licensed corpus | joint MOBI 6 + KF8 boundary record, KF8 half selection |
| `test/resources/mobi/alice-old.mobi`, `alice-kf8.azw3` | licensed corpus | second real copies for reopen and identity tests |
| generated MOBI6/KF8 with `compressionType = 1` (stored) | repository-authored, MIT (`tool`-generated, declared origin) | stored compression subset |
| generated MOBI6/KF8 with `compressionType = 0x4448` (HUFF/CDIC) | repository-authored, MIT (declared origin) | dictionary compression; real-books corpus carries PalmDOC only |

The probe of all real fixtures (in `initial-reference.json`) shows the
licensed corpus covers PalmDOC only; stored and HUFF/CDIC coverage
comes from the generated fixtures, which the protocol explicitly
allows as declared-origin complements to real files.

## Delivered behavior

The session reads PalmDB records through a random-access record table and
builds its reading index with one decompression pass over the text records
at open — decompressed sizes are undeclared in the format, so lengths are
only learnable by decoding; the bytes flow through observers and only the
record → stream-span table stays. MOBI 6 sections tile the stream at the
table-of-contents anchors, splice their share of the globally computed
anchor insertion chain, and clamp to the document body range so fragment
scans never see the head the whole-document text never sees. KF8 parts
assemble one at a time over on-demand record slices; positions resolve over
bounded built-byte windows (1 MiB backward budget), and the linked-aid set
resolves fully at open so any part finalizes in any order with the eager
markup outcome. Resources enumerate lazily via head-only record sniffs;
fonts and covers keep eager names. Images and cross-section links resolve
from the first chapter request. Cover size is checked before loading its
record, and secondary flow text is transient rather than an unbounded
format cache. DRM fails typed before any content work.

Reproduce timing and memory with `tool/mobi_session_bench.dart`. It runs the
eager and session paths in separate fresh processes and records open, first
section and resource timings, stage memory samples and process peak RSS.
The acceptance comparator invokes it for both licensed books and links the
command, result and log hash. Historical warm-process timings are omitted
because they do not describe this isolated measurement method.

The session's open pass reads and decodes the whole stream for the index
(measured: ~456 KB decoded for the 241 KB MOBI 6), which is the declared
index-build cost; nothing is materialized for consumers until a section or
resource is requested. Whole-book walks traverse every section like any
whole-book operation.

## Gate wiring

`oracle_gate.py` runs three stages from the mission manifest:
`version` (`ebook-convert --version`), `reference` (the Calibre
conversions over `build/inputs/` copies), and `compare`
(`tool/mobi_session_compare.dart` writing the case report). Cases
`MS01`–`MS07` must all appear with declared verdicts; skips fail the
gate. All generated artifacts stay under the worktree's `build/`.
