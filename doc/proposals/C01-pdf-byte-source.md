# Proposal: PDF sessions over host byte sources — C01

Status: proposal registered before implementation for coordinator review,
as the campaign protocol requires. C01 implements it on
`codex/unseal-pdf-byte-ranges`, from base `cdd16acc` (1.3.0). C04 does not
depend on it; no other mission consumes the PDF range loader.

Architectural reference: MuPDF's progressive loading chapter — the
document is parsed against a random-access source that serves only the
ranges the parser demands, with the reader owning transport and caching.
MuPDF is the shape reference only; no C build is required or used.

## Public contract

`BookSession.openSource` gains PDF support and a [password] parameter:

```dart
static Future<BookSession> openSource(
  final UnsealByteSource source, {
  final String password = '',
  final SessionPolicy policy = const SessionPolicy(),
})
```

- EPUB, CBZ and now PDF open over a host source. RAR, MOBI/AZW3 and the
  other formats keep their bytes/file opens; the refusal message names
  the format.
- The header contract is unchanged: a complete `PdfBook` (metadata,
  page geometry, navigation, reading order) with placeholder pages,
  `sourceRevision` reporting, exact `loadBytesRange`, and the same
  `loadPdfPageLines` / `loadPdfPageStructure` / search / progression /
  CFI surface as bytes and file sessions.
- Wrong or missing passwords fail with `PdfEncryptedException` exactly
  like the eager parse; DRM-adjacent handlers the library does not
  support stay refused there.

## Where the async boundary sits

The PDF parser (xref chain, object store, page tree, extraction) is a
synchronous, offset-driven implementation over `PdfByteSource` with
sliding 64 KiB windows. All source reads funnel through four call sites
(window refill, stream-body slice, header window, `startxref` tail).
C01 does not fork the parser. It drives the existing implementation
against a **resident range cache with explicit resume**:

- `PdfRangeLoader` owns the async side. Every range the parser demands
  and does not hold is one exact, budget-checked read through the
  session gate — the same `ByteSourceGate` EPUB/CBZ source sessions
  use, on the thread that owns the host source. Fetched ranges merge
  into a disjoint interval store; reads are served from it and always
  copied out, so stream bodies survive later eviction.
- A step driver runs the synchronous parse steps (`PdfDocument.parse`,
  page tree, metadata, outline, per-page extraction) inside a resume
  loop: when a read is not resident the source raises an internal
  demand carrying `(offset, count)`, the driver fetches that exact
  range through the gate, and the step replays from its start. Loaded
  ranges stay pinned until the step completes, so every replay is
  cache-served CPU work and each retry adds at least one range — the
  loop converges in at most (ranges demanded by the step) iterations,
  with a hard iteration cap that fails typed.
- No prefetch reads the file ahead of demand. Open reads the header
  window, the tail window, the xref chain windows, the catalog/page
  tree objects and the sampled pages' objects and streams — and
  nothing else. A host wrapper that downloads the whole PDF and then
  parses is exactly what this design refuses to be; the acceptance
  measurements record every range on the wire.
- Eviction between steps keeps the resident store under a budget
  (default: the session policy's cache budget clamped to at most half
  the source length; never below 1 MiB). Pinned step working sets may
  exceed it; the store never evicts inside a step.
- Budgets are enforced before allocation: a demand above the policy's
  per-request cap fails typed (`ByteSourceLimitExceededException`),
  bounds violations fail `RangeError`, in-flight caps queue
  (backpressure), and gate failures surface as the typed
  `ByteSource*` hierarchy.

Recovery scans that walk the whole file in the eager parse (missing
xref chain, missing `/Length` with a distant `endstream`, the
whole-file object-header scan for an encryption object) keep their
semantics: each scan window is a real demand, so broken documents pay
for the scan ranges they force, and the session reports it through
`metrics()`. On remote opens, a scan that exceeds the demand-iteration
cap fails typed instead of silently reading forever.

## Fixed comparison policy (declared before implementation)

- References: MuPDF 1.26.5 (PyMuPDF, MuPDF core 1.26.10) executed from
  the campaign venv over read-only copies of committed fixtures;
  Poppler `pdftotext` from the Calibre bundle as the optional second
  reference. Version, command and exit code recorded per run.
- Text: Dice coefficient over character bigrams after the shared fold
  (ligatures, quotes, dashes, ellipsis; whitespace collapsed;
  casefolded) — the same normalization `tool/pdf_parity.dart` fixed in
  the 1.3.0 PDF mission. Page passes at ≥ 0.90.
- Geometry: page width/height/rotation compared exactly against MuPDF
  per page. Line-level geometry parity is documented session-vs-eager
  (same profile), because line segmentation is parser-specific.
- Navigation: outline titles and target pages compared against
  `Document.get_toc()`.
- Local parity: per fixture, session output (canonical page text,
  lines, structure, search, progression, anchors, metrics identity)
  must equal the eager parse on the same bytes.

## Fixed fixtures and ceiling (declared before implementation)

The two large independent PDFs for the partial-reading acceptance, both
already committed with provenance and SHA-256:

| Fixture | Bytes | Origin |
| --- | ---: | --- |
| `test/resources/pdf/jbig2/jbig2_huffman_2.pdf` | 2,350,192 | pdf.js test corpus (Apache-2.0), SHA-256 pinned in the fuzz manifest |
| `test/resources/books/pdf/elements-of-euclid-pg.pdf` | 1,860,807 | Project Gutenberg #21076 download, pinned in `test/resources/books/manifest.json` |

Ceiling, fixed from the pre-implementation structural measurement of
the eager parser's read pattern (build probe, 2026-10-17): **open plus
first content past the sample must request strictly less than 50% of
the file's bytes (unique coverage on the wire) from each fixture, and
the session must not retain a complete-file buffer** (resident range
bytes peak below half the source length). Measured eager baselines the
async path must not multiply: jbig2_huffman_2 ≈ 16.4% open+first
content, euclid ≈ 34.5%. Deviations get fixed at the cause; the
ceiling is not moved after observing a result.

Corpus for the reference comparison (structure cut of the existing
subset): `dickens-sample.pdf` (classic xref), `pg2701-generated.pdf`
(classic xref, 354 pages), `elements-of-euclid-pg.pdf` (xref stream +
object streams), `jbig2_huffman_2.pdf` (xref stream + object streams),
`pr6531_1.pdf` (incremental update, linearized, AES-256 R6, password
`asdfasdf`), `r6.pdf` (AES-256 R6, password), `r3-rc4-128.pdf`
(RC4-128 R3, password).

## Files this mission owns or touches

- New: `lib/src/features/pdf/reader/pdf_range_loader.dart` (loader,
  resident source, demand type, step driver), the async open entry
  used by `SessionEngine.openRemote`.
- Changed: `SessionEngine.openRemote` (PDF branch),
  `BookSession.openSource` (password parameter, docs), session metrics
  wiring for remote PDF reads, README/guides/CHANGELOG.
- Shared-file coordination: `lib/unseal.dart` gains no new exports
  beyond what `book_session.dart` re-exports; worker wire files change
  only if the refusal message text does. `web/unseal_worker.dart` and
  the `byteSource.v1` bridge are reused unchanged; the compiled worker
  must be rebuilt for web lanes.
