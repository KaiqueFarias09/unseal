# Unseal roadmap

This is the single backlog for Unseal, reviewed against the code on
October 15, 2026. It records unfinished work from earlier plans. Items are
proposals unless stated otherwise; they are not promises for version 1.2.0.
The [README](../README.md#supported-formats) defines support available today.

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

## Completing an item

When an item ships, document its public behavior in the README or the
relevant maintained guide, record the change in the changelog, and remove
the completed work from this backlog. Keep only its remaining acceptance
gaps here. Historical plans and campaign reports belong in Git history.
