# Unseal roadmap

This is the single backlog for Unseal, reviewed against the code on
October 16, 2026. It records unfinished work from earlier plans. Items are
proposals unless stated otherwise; they are not promises for version 1.2.0.
The [README](../README.md#supported-formats) defines support available today.

The [five-agent implementation plan](parallel-implementation.md) defines the
contracts and execution of structured PDF, indexed search, compressed RAR5,
JPEG2000, and durable annotations. It does not mark those items implemented.

EPUB fixed-layout data, progressive EPUB/CBZ/CBR/PDF sessions, concurrent
browser sessions, DjVu shared dictionaries, TXTz/NAVM, indirect file opening,
and TIFF/BigTIFF parsing are already implemented. They are not backlog items.

## Reading positions and text stability

### R1. Preserve PDF positions across extraction modes

Current behavior: a PDF session builds its reflow plan from a sample of up
to 20 pages. Full parsing uses all pages. For longer PDFs, the two plans can
produce different canonical text and offsets. Within a session, document text
and page-line text use the same plan.

Pending work: define a stable source text space or explicit mappings between
extraction modes before promising interchangeable persisted positions.

Acceptance: annotate a PDF longer than the sample, materialize all pages,
close and reopen it, and switch between session and full parsing. The same
passage must resolve, or the API must report a migration, ambiguity, or
missing target explicitly. Test different fonts, repeated headers, columns,
and continuation lines beyond the sample.

### R2. Define progression for non-linear EPUB items

Current behavior: `readingOrder` preserves spine occurrences, including
`linear="no"`. `BookProgression` measures all reading-order sections.

Pending work: decide whether to expose an explicit progression policy for
linear content without changing the preserved source order.

Acceptance: cover auxiliary non-linear sections and repeated spine paths;
keep progression indexes aligned with the chosen order and document the
effect on stored positions.

## Scanned-page text and geometry

### R3. Add a shared spatial reading contract

Current behavior: PDF exposes lines, coordinates, and extraction diagnostics.
DjVu exposes page images and hidden text; TIFF exposes page images. They do
not share a complete word-level geometry and text-origin contract.

Pending work: model page transforms, regions, lines, words, canonical ranges,
language, origin, and confidence where the source supplies them. Reuse
`PdfPageText` and resolve R1 before persisting derived positions.

Acceptance: verify coordinate transforms on rotated and multi-column pages,
distinguish native text from imported OCR, and preserve uncertainty and source
identity. A consumer must be able to map a text range back to its page region.

OCR engines, model downloads, queues, persistent caches, selection UI, and
speech belong to consumers or optional adapters. A demonstration needs a real
OCR provider and annotated reference pages; mocked recognition does not prove
text quality. These integrations must not add Flutter, native binaries, or
network services to Unseal's required runtime.

## Large publications

### R4. Extend progressive sessions to MOBI and AZW3

Current behavior: both formats use full parsing; `BookSession` rejects them.

Proposed order: unencrypted MOBI first, then AZW3/KF8. Reuse PalmDB record
indexing, verify the actual compression dependencies in each file, and retain
the existing resource paths and reading order. HUFF/CDIC state may limit the
benefit of deferring individual records.

Acceptance: compare session and full parsing for text, resources, navigation,
and positions on licensed files. Test concurrent sessions, cancellation,
malformed records, and VM/browser transport. Measure opening, first content,
and peak memory in alternating runs; report regressions as well as gains.

CHM sessions remain deferred. Its LZX stream can require shared decompression
state. Revisit only with evidence that bounded session behavior benefits real
files; do not label full decoding in a worker as progressive loading.

### R5. Support external byte sources and reusable indexes

Current behavior: sessions accept bytes or a filesystem path. The internal
PDF byte source reads synchronously; it is not a public HTTP-range interface.

Pending work: design a versioned byte-source boundary with length, identity,
revision, cancellation, and lifecycle. Prove how asynchronous host reads
cross an isolate or worker boundary, with bounded requests and backpressure.
Applications retain HTTP, credentials, retries, and storage ownership.

Acceptance: exercise partial and incorrect ranges, revision changes, missing
lengths, distant seeks, two sessions, and closure during reads. Validate index
schema, source identity, and integrity before reuse. Measure bytes actually
read and transferred, including queued resources and prefetch. Invalid or
stale indexes must rebuild safely or fail explicitly.

Incremental search should expose partial versus complete coverage and remain
cancelable. Prefetch must share a total memory budget with the visible page,
cache, queued messages, and resources in transit.

## Interoperability

### R6. Add standard adapters where consumers need them

| Proposal | Existing contract | Work still needed |
| --- | --- | --- |
| OPDS 2 JSON | `OpdsFeed.parse` reads OPDS Atom XML. | Define JSON publication/navigation mapping, links, pagination, and malformed-input behavior. Unseal parses catalogs; applications fetch them. |
| Readium locators and position lists | Native text, page, and CFI locators exist. | Define supported mappings, source identity, progression, and position-list generation. Do not imply that a native locator already conforms to Readium. |
| W3C annotation exchange | Native bookmark/highlight codecs exist. | Add an explicit adapter with source edition, selectors, context, text revision, and deterministic round trips. Preserve ambiguous and missing reanchoring outcomes. |

Choose the adapter boundary and public API from a concrete consumer use case.
Do not replace the existing contracts solely to match an external schema.

## Format coverage and compatibility evidence

### R7. Extend unsupported format features when fixtures justify them

| Format | Candidate work | Current boundary |
| --- | --- | --- |
| DjVu | `FGjp`, `Smmr`, `FGbz` palette colors, chained shared dictionaries, annotations, and `BMKz`. | Replacement visual codecs and chained dictionaries fail typed. Palette recoloring, annotations, thumbnails, and `BMKz` are ignored. Composed output uses a hard mask rather than ddjvu's blended stencil. |
| TIFF/BigTIFF | Tiled and planar raster, palettes, additional sample formats, external JPEG tables, multi-strip JPEG, old JPEG, reversed FillOrder, and further predictors. | Unsupported layouts/codecs fail with typed exceptions. Support must remain bounded before allocation. |
| PDF images | JPEG2000 decoding and `JPXDecode` integration. | The image extraction path handles JPEG, CCITT, and JBIG2; unsupported image filters can leave geometry without extracted pixels. This is distinct from Grimoire's PDF.js rendering. |
| CBR/RAR5 | Compressed entries, filters, checksums, and bounded handling of solid archives. | The RAR5 reader currently extracts stored entries only. Do not describe the existing RAR4 decoder as compressed RAR5 support. |
| CHM | More codepages, merged help, and full-text index data. | Reading covers supported HTML topics/resources and the documented codepages. |
| Plucker/eReader | More record and bitmap variants, with independent fixtures. | Existing reading-oriented formatting, resources, links, and navigation remain supported. |
| RTF and LRF | Richer document fidelity when required by a reading use case. | RTF omits complex layout/images; LRF is reflowed content rather than exact Sony page layout. |

Every extension needs a redistributable fixture, provenance, an independent
reference where available, typed failures, resource limits, and VM/browser
coverage. Unsupported DRM remains outside scope.

### R8. Broaden independent corpus coverage

- KEPUB: a redistributable file produced by Kobo itself. Independent Standard
  Ebooks and Kepubify files already exercise the EPUB path.
- LRF: a valid file from an independent writer or Sony device, including
  legacy versions. Current valid fixtures are Calibre-generated; legacy
  headers are synthetic. The evaluated Eruditio output is invalid in both
  readers and must not be promoted as compatibility evidence.
- LRX2: independently licensed plaintext metadata samples. Protected content
  remains rejected; this is not a proposal to decrypt it.
- CHM: real Intel E8-enabled streams and codepages beyond 1251/1252/1256.
  E8 decoding already exists, but its current evidence is synthetic.
- Plucker/eReader: independent rich PML, footnote/sidebar records, custom
  palettes, RGB565 images, and additional compressed bitmap variants.
- DjVu: more IW44 producers, third-party indirect documents, and fixtures for
  the unimplemented chunks in R7. Derived indirect fixtures do not establish
  third-party compatibility.
- TIFF: independently produced, licensed multi-page scanned books beyond
  libtiff's test corpus and generated transcoding cases.

Keep licenses, hashes, expected results, and rejected-candidate explanations
beside fixtures. Synthetic cases remain useful but must be labeled as such.

## Verification infrastructure

### R9. Measure coverage and consumer performance reproducibly

The deterministic mutation harness and corpus checks already exist. Add a
repeatable coverage comparison before using coverage gains as a recurring
quality gate. Retain cases that reach new behavior and preserve crash,
exception, and timeout signatures during minimization.

For performance work, use the [development guide](development.md#measure-performance).
Do not carry historical timings forward as current guarantees. Consumer
rendering, background audio, mobile transition variance, and visible-page
timing require tests in their own applications and representative devices.

### R10. Add optional indexed search — delivered within its declared subset

Shipped: an optional per-publication inverted index (`BookSearchIndex`) with
BM25+ ranking, prefix and bounded fuzzy modes, incremental cancellable
construction with coverage accounting, versioned serialization with
pre-allocation import validation and digest-based invalidation, and session
integration across inline, isolate, and Web Worker paths. Hits cut the same
canonical UTF-16 ranges `Book.search` addresses; exact-query ranges match an
independent scan (tested), and accents, soft-hyphen splits, astral text,
repeated spine items, cancellation, and VM/browser determinism are covered by
the search suites. `Book.search` is unchanged.

Remaining in R10: persisting an index over PDF text awaits the campaign's P1
position-mapping acceptance — indexes over PDF sessions build and query in
memory but refuse to serialize. A library-wide persistent catalog stays out of
scope: applications own persistent storage. See the changelog's Unreleased
section for the delivered contract and limits.

## Reference implementations for larger campaigns

Research snapshot: `dart-port-campaigns`, version 1.0, draft, October 16, 2026.
This section records implementation leads in the same backlog rather than
creating separate proposal documents. Grimoire work is identified explicitly;
it does not belong in Unseal's parsing runtime.

### Research scope and current evidence

The four axes are current gaps, portable algorithms, source licensing, and
independent verification. These are engineering recommendations, not measured
claims about any AI model's performance.

- Current gaps: search scans sections, RAR5 extracts stored entries, PDF image
  extraction omits JPEG2000, and spatial PDF text is line-oriented. See
  [search](../lib/src/features/search/book_search.dart),
  [RAR5](../lib/src/features/comic/archive/rar_reader.dart),
  [PDF images](../lib/src/features/pdf/reader/pdf_content_stream.dart), and
  [PDF geometry](../lib/src/features/pdf/entities/pdf_page_text.dart).
- Portable algorithms: PdfPig separates word extraction, block segmentation,
  and reading-order detection. Those stages can build on Unseal's PDF parser
  instead of replacing it. Table detection requires additional geometry and
  algorithms, such as Tabula's extractors. See
  [PdfPig layout analysis](https://github.com/UglyToad/PdfPig/wiki/Document-Layout-Analysis)
  and [Tabula Java](https://github.com/tabulapdf/tabula-java).
- Layout scope: litehtml computes HTML/CSS layout and delegates drawing to its
  host. WeasyPrint provides a separate reference for paged layout. Neither is
  a ready-made native Flutter ebook engine; pagination, selection, shaping,
  accessibility, and publication positions still need integration. See
  [litehtml](https://github.com/litehtml/litehtml) and
  [WeasyPrint architecture](https://doc.courtbouillon.org/weasyprint/stable/going_further.html).
- Search scope: MiniSearch supplies a compact in-memory design with prefix,
  fuzzy, and ranked search. Tantivy is a reference for larger segmented
  indexes, not an instruction to port an entire search server. See
  [MiniSearch design](https://github.com/lucaong/minisearch/blob/3d239d1c3ae7aef1bf5d8945dd7b5f0709f646f5/DESIGN_DOCUMENT.md)
  and [Tantivy architecture](https://github.com/quickwit-oss/tantivy/blob/e1acb3e0112f2b4819946aa4ea5742bf429853d8/ARCHITECTURE.md).

### Campaign comparison and acceptance

| Campaign and owner | Reference implementation | Bounded first delivery | Evidence required |
| --- | --- | --- | --- |
| Structured PDF reading: Unseal R1/R3, then Grimoire interaction | PdfPig (C#, Apache-2.0); Tabula Java (Java, MIT) | Words, blocks, columns, reading order, and mappings to canonical ranges. Add table extraction as a separate stage with access to ruling geometry. | Independently annotated rotated and multi-column pages; compare words/regions with the reference and reading order with human expectations. Verify stable positions between full and progressive parsing. |
| Indexed search: Unseal R10, then Grimoire presentation | MiniSearch (TypeScript, MIT); Tantivy (Rust, MIT) | One-publication index, ranked/prefix/fuzzy queries, serialization, and exact source ranges. | Differential exact-match cases; expected relevance cases; real VM/browser latency and memory measurements, including index construction. |
| Compressed RAR5: Unseal R7 | [rardecode](https://github.com/nwaples/rardecode) (Go, BSD-2-Clause); libarchive as a second decoder | Non-solid compressed entries and filters first; bounded solid-block reuse separately. | Byte-identical extraction against independent decoders; CRC failures, malformed blocks, dictionary limits, cancellation, and browser execution. |
| JPEG2000: Unseal R7 | [OpenJPEG](https://github.com/uclouvain/openjpeg) (C, BSD-2-Clause) | A documented decoder subset, then PDF `JPXDecode` integration. Encoding is outside the first delivery. | Exact samples for supported lossless cases; specified tolerances for lossy/color conversions; oversized dimensions, malformed markers, tiles, and bounded allocation. |
| Durable annotations: Unseal R6 contracts, Grimoire relocation/UI | [Hypothesis anchoring](https://github.com/hypothesis/client/blob/a7b7400d0d706d4357ec37c2a3610b25dcca89d5/src/annotator/anchoring/html.ts) (TypeScript, BSD-2-Clause with separately licensed subcomponents); [Readium](https://github.com/readium/kotlin-toolkit) (Kotlin, BSD-3-Clause) | Text quote/context and position selectors, revision-aware relocation, W3C exchange, and explicit ambiguous/missing outcomes. Build on existing highlights, CFI, and fuzzy relocation. | Repeated passages, changed markup, corrected editions, Unicode normalization, and reopen/import/export cases. Never silently attach to another matching passage. |
| Native EPUB layout: Grimoire | litehtml (C++, BSD-3-Clause); WeasyPrint (Python, BSD-3-Clause) | An optional native renderer for a declared HTML/CSS subset; begin with paragraphs, inline spans, images, lists, and page breaks. | Identical-book comparisons with the existing renderer, golden pages, RTL/shaping, links, canonical-range selection, accessibility, and measured memory/page-turn behavior. |

### Source revisions and licensing

The primary license texts were inspected at the revisions below. These are
research pins, not vendored dependencies or a guarantee covering every file,
fixture, optional dependency, font, or model. A port must preserve applicable
copyright, license, and NOTICE requirements and inspect the files it uses.

| Source | Inspected revision | Primary license |
| --- | --- | --- |
| litehtml | `8848b99b1fae` | [BSD-3-Clause](https://github.com/litehtml/litehtml/blob/8848b99b1fae17026117c45c3ec9cd3e38b2e511/LICENSE) |
| WeasyPrint | `da3eb66e207f` | [BSD-3-Clause](https://github.com/Kozea/WeasyPrint/blob/da3eb66e207f40d96be8a9fff05a90a4aae5c1a2/LICENSE) |
| PdfPig | `3452b9fb5244` | [Apache-2.0](https://github.com/UglyToad/PdfPig/blob/3452b9fb52440202fa30b8dd8bf57c5186f8de29/LICENSE) |
| Tabula Java | `2cdf3b4fd3f7` | [MIT](https://github.com/tabulapdf/tabula-java/blob/2cdf3b4fd3f7e921dca8cc6814cdd9316be40f0f/LICENSE) |
| MiniSearch | `3d239d1c3ae7` | [MIT](https://github.com/lucaong/minisearch/blob/3d239d1c3ae7aef1bf5d8945dd7b5f0709f646f5/LICENSE.txt) |
| Tantivy | `e1acb3e0112f` | [MIT](https://github.com/quickwit-oss/tantivy/blob/e1acb3e0112f2b4819946aa4ea5742bf429853d8/LICENSE) |
| rardecode | `ad22ba91a2ab` | [BSD-2-Clause](https://github.com/nwaples/rardecode/blob/ad22ba91a2ab0d3ff6bca20cd978b33ee78faab1/LICENSE) |
| OpenJPEG | `8314119b067c` | [BSD-2-Clause](https://github.com/uclouvain/openjpeg/blob/8314119b067c0fc77834731168daaebd379fdb12/LICENSE) |
| Hypothesis client | `a7b7400d0d70` | [BSD-2-Clause and subcomponent terms](https://github.com/hypothesis/client/blob/a7b7400d0d706d4357ec37c2a3610b25dcca89d5/LICENSE) |
| Readium Kotlin | `89b96c20c447` | [BSD-3-Clause](https://github.com/readium/kotlin-toolkit/blob/89b96c20c447d0aec17db57a06456b7decffde4c/LICENSE) |

### Recommended order and open questions

Start with indexed search for a bounded end-to-end delivery, or structured PDF
reading for the largest immediate reading-quality opportunity. Compressed
RAR5 is a particularly suitable isolated port because output can be compared
byte for byte. JPEG2000 is a larger codec effort. Native EPUB layout is the
largest architectural investment and should begin with a compatibility corpus
and a declared CSS subset before replacing any renderer.

For every campaign, pin the reference, build its comparison harness first,
use licensed fixtures, integrate a small public entry point, and require
documentation, benchmarks, typed failures, and VM/browser validation. Separate
implementation from an independent review of the resulting diff and evidence.

Open questions are corpus prevalence for unsupported codecs, target-device
budgets, the native renderer's CSS subset, and which annotation exchange a
consumer actually needs. No estimate of AI credits or delivery time has been
validated. OCR runtime/model selection, DRM, network ownership, and application
persistence are outside these ports.

The five Unseal campaigns now use the
[implementation plan](parallel-implementation.md). Native EPUB layout remains
a separate Grimoire proposal. Keep remaining work in this backlog and remove
completed scope only when its acceptance criteria pass.

## Completing an item

When an item ships, document its public behavior in the README or the
relevant maintained guide, record the change in the changelog, and remove
the completed work from this backlog. Keep only its remaining acceptance
gaps here. Historical plans and campaign reports belong in Git history.
