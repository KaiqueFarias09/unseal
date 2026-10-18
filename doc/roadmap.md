# Unseal roadmap

This is the backlog for Unseal, reviewed on October 18, 2026. The
[README](../README.md#supported-formats) defines the behavior available in 1.3.0.
Structured PDF, indexed search, solid RAR 5 decoding, the JPEG 2000 subset,
durable annotations, DjVu/ALTO spatial text, EPUB diagnostics, MOBI/AZW3
sessions, PAGE XML, tiled TIFF/BigTIFF, OPDS 2.0, unsigned 8–16-bit
JPEG 2000 component grids, Readium locators/position lists, hOCR import,
planar/palette TIFF, RAR5 BLAKE2sp, and asynchronous EPUB/CBZ/PDF byte sources are
implemented. Remaining
extensions are listed below.

## Reading positions and text stability

### R2. Define progression for non-linear EPUB items

Current behavior: `readingOrder` preserves spine occurrences, including
`linear="no"`. `BookProgression` measures all reading-order sections.

Pending work: decide whether to expose an explicit progression policy for
linear content without changing the preserved source order.

Acceptance: cover auxiliary non-linear sections and repeated spine paths;
keep progression indexes aligned with the chosen order and document the
effect on stored positions.

## Scanned-page text and geometry

### R3. Extend OCR interchange and spatial bindings

Current behavior: DjVu hidden text, ALTO v2/v3/v4, hOCR, and PAGE XML 2019-07-15
expose positioned text, UTF-16 ranges, provenance, confidence, and verified snapshot binding. PDF has
its own structure and source-anchor contract. TIFF exposes page images.

Pending work: broader hOCR producer coverage and consumer integration of
the existing host-confirmed snapshot bindings for TIFF or image-only PDF pages. PAGE already preserves polygons and nested reading order.
OCR execution, queues, storage, and rendering remain consumer responsibilities.

Acceptance: real independently produced OCR sidecars, schema validation where
available, rotated/multi-column pages, ambiguous text, bounded projection work,
and end-to-end search and durable anchors on VM and browser.

## Large publications

### R4. Extend measured progressive reading

Current behavior: EPUB, CBZ and PDF support asynchronous host-owned byte
sources with revision checks, exact range reads and isolate/worker transport.
PDF reads xrefs, object windows and page streams on demand under bounded
working sets. MOBI/AZW3 sessions materialize records locally; CBR keeps
bounded local solid state.

Pending work: independently produced large and damaged PDFs, more layout
and encryption variants, and measured distant-page latency on consumer
transports. Preserve exact range accounting and typed resource limits.

CHM sessions remain deferred. Its LZX stream can require shared decompression
state; revisit only with measurements on real files.

## Interoperability

### R6. Add standard adapters where consumers need them

| Proposal | Existing contract | Work still needed |
| --- | --- | --- |
| Readium locators and position lists | Bounded Locator interchange, verified format mappings and deterministic position lists ship under a versioned Unseal density profile. | Additional producer profiles and consumer-driven mappings; preserve resource/occurrence identity and explicit approximation. |
| W3C annotation exchange | Native bookmark/highlight codecs exist; `W3cAnnotationAdapter` ships the TextQuoteSelector/TextPositionSelector subset with code point/UTF-16 conversions and explicit unsupported-selector reporting. | Broader selector coverage (Range, SVG, data position, fragments), annotation-body serialization, and a consumer-driven decision on preserving versus rejecting unknown fields per direction. |

Choose the adapter boundary and public API from a concrete consumer use case.
Do not replace the existing contracts solely to match an external schema.

## Format coverage and compatibility evidence

### R7. Extend unsupported format features when fixtures justify them

| Format | Candidate work | Current boundary |
| --- | --- | --- |
| DjVu | `FGjp`, `Smmr`, `FGbz` palette colors, chained shared dictionaries, annotations, and `BMKz`. | Replacement visual codecs and chained dictionaries fail typed. Palette recoloring, annotations, thumbnails, and `BMKz` are ignored. Composed output uses a hard mask rather than ddjvu's blended stencil. |
| TIFF/BigTIFF | Planar raster, palettes, additional sample formats, external JPEG tables, multi-strip JPEG, old JPEG, reversed FillOrder, and further predictors. | Unsupported layouts/codecs fail with typed exceptions. Support must remain bounded before allocation. |
| PDF/JPEG 2000 | Signed or mixed sample depths, additional progression orders, coding styles, calibrated/ICC color spaces, palettes, and alpha. | The documented Part 1 subset decodes to grayscale/RGB images; unsupported features fail typed. |
| CBR/RAR5 | RAR 4 PPMd/VM streams. | RAR 5 compression, including bounded solid history, ships: algorithm version 0, methods 1-5, delta/E8/E8-E9/ARM filters, header/data CRC-32 (zero included) and declared BLAKE2sp data hashes, dictionaries through 64 MiB, UTF-8 names, eager and session parity, VM and worker execution. Split, encrypted, linked, later-version, and oversized-dictionary records reject typed. |
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
the completed work from this backlog. Historical plans and campaign reports
belong in Git history.
