## Unreleased

### Added

- Readium Locator interchange and deterministic position lists
  (`doc/readium-locators.md` is the normative contract). The
  `ReadiumLocator`/`ReadiumLocations`/`ReadiumTextContext` model mirrors
  the executed `@readium/shared` 2.8.0 toolkit over the pinned corpus
  (required `href`+`type`, tolerant `#fragment` split and legacy
  singular `fragment` on import, out-of-range progression/position
  dropped, opaque bounded extensions, service-shape serialization).
  Conversions to and from the `BookLocator` union report exactly one
  outcome — exact, approximate, ambiguous, or unsupported — with EPUB
  CFI confirmed through the existing resolver, PDF `page=N` fragments
  converted explicitly against the zero-based native page index, and
  comic pages addressed by their resource hrefs; verified reuse requires
  publication revision, occurrence, and text-profile context. Position
  lists generate under the versioned `unseal.readium.positions/1`
  profile (reflowable anchors every 1024 Unicode scalars plus the first
  position of each occurrence, one position per PDF/comic page, UTF-16
  public offsets, documented formulas, empty and non-linear handling),
  deterministically over eager books and live `BookSession`s with
  observable coverage and cancellation between steps. All JSON inputs
  are bounded before allocation and fail typed. Validated against the
  official toolkit, the pinned official Locator schema, and an
  independent position-list verifier in `tool/readium/`.
- TIFF/BigTIFF planar RGB and palette pages (contract in
  `doc/tiff-planar-palette.md`): `PlanarConfiguration` 2 for RGB unsigned
  8/16-bit, three samples per pixel, by strips and tiles in classic and
  BigTIFF files and both byte orders, with Predictor 2 accumulating on a
  one-sample stride per plane; and `PhotometricInterpretation` 3 palettes
  of 1/2/4/8-bit indices with an exact-size 16-bit ColorMap whose native
  values are preserved before the fixed display projection (byte-range
  legacy tables used directly as libtiff's "Assuming 8-bit colormap"
  rule, full-range tables take the high byte). Palette + Predictor 2,
  palette + CCITT, 16-bit palettes, planar alpha/extra samples, and
  planar CCITT/JPEG stay typed rejections. Every planar band segment is
  validated (bounds, header, directory, mutual overlap across bands)
  before any band decodes; resident budgets count all three band
  buffers, the ColorMap tables, and the display lookup together.
  Verified sample-by-sample against libtiff 4.7.2 — 49-case corpus over
  independent SGI/GraphicsMagick files and identified derivatives with
  native band samples, palette indices, ColorMaps, and RGBA pixels at
  zero tolerance (`tool/tiff_planar_palette_compare.dart`), on the VM and
  under a real browser worker.
- hOCR OCR import (`lib/hocr.dart`): pages, content areas, paragraphs,
  lines and words in the nesting the producer declared — Tesseract
  (including its 4/5 `ocr_header`/`ocr_caption`/`ocr_textfloat`
  line-role classes), ABBYY, ocropy, OCRopus, kraken and gcv2hocr
  shapes — with producer metadata, integer pixel boxes, the native
  baseline polynomial with named page-space projections, text angles
  that never rotate coordinates, scan resolution, and every unconsumed
  `title` property verbatim. The 0..100 `x_wconf` scale converts
  explicitly to the shared 0..1; absent, unknown and zero confidence
  stay distinct. `order` and `cflow` refuse typed.
- `bindHocrToSnapshot`: binds hOCR text onto a host-provided canonical
  snapshot with the shared reading cursor, bounded ambiguity candidates
  and projection budget; a line's region zone is its nearest boxed
  ancestor and frameless pages bind without a spatial projection.
  `UnsealWorker.bindHocrInWorker` serves the same binding in the browser
  worker. Bounded preflight before any DOM: 32 MiB input, 128 tag
  levels, one million elements, per-page/line/word budgets, title and
  attribute caps; corruption fails typed. Subset, title grammar,
  producer policies, TSV normalization, corpus and limits are specified
  in `doc/hocr.md`, and the executed reference lane (Tesseract 5.5.3
  hOCR+TSV same-pass runs over Apache-2.0 images, eight CC0 sidecars
  from ocr-fileformat-samples, and an independent lxml extractor the
  Dart parser is diffed against) lives in `tool/hocr_*`.

## 1.3.0 - October 18, 2026

### Added

- OPDS 2.0 JSON catalog parsing through `parseOpds2Feed`,
  `parseOpds2Publication`, and the `Opds2*` model: navigation,
  publications, nested groups, facets, named subcollections, contributor
  roles, subjects, images, acquisition links with
  price/indirectAcquisition/holds/copies/availability properties, `rel`
  as string or list, and pagination metadata. Links stay data; relative
  references resolve only against a base URL the caller passes
  (`resolveOpds2Href`), URI templates stay data with a documented
  `{var}`/`{?var}` expansion subset, and unknown schemes are never
  fetched. Input is bounded before allocation (16 MiB bytes, 64 depth,
  250k values, 1 MiB strings, per-collection counts under `Opds2Limits`)
  and failures are typed (`Opds2MalformedException`,
  `Opds2LimitExceededException`) with JSON pointers. Rules the official
  schemas do not enforce but the normative text requires (facet titles,
  search `{?query}` templates, RFC 3339 timestamps) reject separately;
  the schema-vs-normative table and the extension policy live in
  `doc/opds2.md`. Validated against the pinned official OPDS/Readium
  schema closure (jsonschema 4.25.1 + referencing 0.37.0, 26 schemas by
  SHA-256) over the real Feedbooks OPDS 2.0 test catalog and canonical
  specification examples, with the same corpus embedded for the Chrome
  suite. The OPDS 1.x Atom API is unchanged; networking, authentication,
  purchase/loan flows, and DRM stay out of scope.
- PAGE XML OCR import (`lib/page.dart`, exactly the 2019-07-15
  namespace): metadata, page identity and dimensions, all fifteen
  region kinds, text regions with lines and words, native integer
  polygons with explicitly derived bounding boxes, baselines, the
  nested reading order (ordered and unordered groups with deterministic
  index sequencing, validated references, duplicate and cycle
  refusals), and `TextEquiv` alternatives with declared index,
  confidence, and language. Orientation stays a display-space hint; an
  exact 90-degree multiple projects as the spatial page's rotation and
  fractional skew stays native. Descriptive enumeration tokens travel
  verbatim as declared data.
- `bindPageToSnapshot`: binds the chosen TextEquiv content onto a
  host-provided canonical snapshot at the finest declared granularity —
  words, then lines whose words carry none, then regions without
  text-bearing lines — reusing the shared spatial contract, the UTF-16
  ranges, the reading cursor, bounded ambiguity candidates, and the
  projection work budget. The binding preserves the target identity
  tuple, the OCR origin, the creator, and confidence presence.
- The `pageXml.bind` worker op over the `pageSource`/resident-book
  protocol, mirroring `spatial.altoBind`, with the PAGE typed failures
  registered in the error wire and `UnsealWorker.bindPageXmlInWorker`
  on the facade.
- Bounded preflight before any allocation: 32 MiB input, 128 XML
  levels, one million elements per document and 65,536 per page, and
  caps on regions, lines, words, polygon points, alternatives,
  reading-order entries, and group depth; corruption fails typed.
- `doc/page-xml.md` records the subset, policies, limits, and the
  executed reference lane: the official PAGE 2019-07-15 XSD over the
  licensed OCR-D `gt_structure_text` corpus (CC-BY-SA-4.0, four works
  printed 1506–1897) with an independent lxml extractor whose records
  the Dart parser matches field by field, plus nine XSD negatives, one
  declared schema-valid parser negative, and one declared
  accepted-as-data enumeration negative.
- Tiled TIFF and BigTIFF pages decode through the existing entry points
  with the strip codecs: uncompressed, PackBits, LZW, Deflate with
  Predictor 2, and CCITT modified Huffman, Group 3, and Group 4 at the tile
  width, for gray 1/2/4/8/16-bit and RGB 8/16-bit pages. Tile grids decode
  every tile at its full footprint before the page takes the visible part,
  tile addresses are read from `TileOffsets`/`TileByteCounts` or from the
  strip tags that Silicon Graphics files use, Orientation 2-4 are flipped to
  top-left, and multi-IFD documents mix strips and tiles in either byte
  order with classic or 64-bit addresses. Every tiled layout of the matrix
  is compared sample by sample and through the RGBA conversion with libtiff
  4.7.2 over SGI-written files, libtiff test images, and identified `tiffcp`
  derivatives (`doc/tiff-tiles.md`, `test/resources/tiff/tiled/`).
- TIFF decode budgets gained independent guards for resident bytes (page
  images plus the live RGB conversion and segment scratch) and for decode
  work counted at full strip/tile footprints (512 MiB per document), so a
  small page cannot pay for oversized temporary tiles; segment layouts are
  validated as a whole before any allocation, including overlaps with the
  header, the page's directory, and each other; Deflate segments inflate
  straight into their footprint and stop there.
- `SampleFormat` 4 (void) is read as unsigned integer samples, as libtiff
  reads the obsolete SGI `DataType` tag that `tiffcp` re-emits.
- JPEG 2000 `JPXDecode` decoding of unsigned 8- to 16-bit components and
  subsampled component grids: per-component `XRsiz`/`YRsiz` sample grids with
  image origins, odd sizes and partial edge tiles upsampled to the reference
  grid, JP2 sYCC converted to RGB with the reference's 4:4:4/4:2:2/4:2:0
  rules, and 16-bit PNG extraction (bit replication with an `sBIT` chunk
  declaring the native precision) for images above 8 bits. The accepted
  contract, the upsampling/colour/lossy policies and the three comparison
  lanes against libopenjp2 2.5.4 are fixed in `doc/jpeg2000-precision.md`;
  every lossless fixture matches the reference byte-exactly and ffmpeg 9.0.2
  serves as the independent producer for the `real-*` fixtures. 8-bit
  behaviour, typed refusals and existing public APIs are unchanged; signed,
  mixed-precision, palette, alpha, ICC and Part 2 inputs still fail typed.

- PDF progressive sessions over host byte sources:
  `BookSession.openSource` opens a PDF through the host's
  `UnsealByteSource` (with a `password` for encrypted documents), and
  the parser reads demand-driven — the `startxref` tail, the xref
  chain, the object windows and each materialized page's streams
  arrive as separate, budget-checked exact ranges. Open plus first
  content stays a small fraction of a normally shaped document
  (measured: ~13% of a 2.3 MB scanned fixture, ~35% of a 1.9 MB
  designed fixture, against a 50% ceiling fixed before
  implementation). Nothing is read ahead of demand, retained ranges obey the
  cache working-set budget, and recovery scans on
  damaged documents keep the eager parse's semantics with every
  scanned window a counted range. `session.metrics()` exposes the
  range ledger (attempts, returned bytes, unique offsets, resident peak,
  resumes, queued-step peak) as the public evidence channel; EPUB,
  CBZ, CBR, MOBI 6 and AZW3/KF8 sessions and all bytes/file opens are
  unchanged. The acceptance matrix compares against MuPDF 1.26.5
  under the fixed fold + Dice policy (a pinned per-page digest profile
  records known extraction differences on the Byrne Euclid plates),
  executes the real VM/Chrome/fuzz/corpus lanes, and measures open, first content,
  distant jump and peak RSS per process
  (`tool/pdf_mupdf_reference.py`, `tool/pdf_range_compare.dart`,
  `tool/pdf_session_bench.dart`).

- EPUB structural diagnostics through `diagnoseEpub` and
  `diagnoseEpubArchive`: deterministic findings with stable rule IDs,
  severities, resources, locations, and reasons for the OCF container and
  mimetype, the OPF package and manifest, the spine, and EPUB 2/3
  navigation and guide references, including percent-encoded paths and
  fragments. Reading behavior, typed failures, and safety boundaries are
  unchanged; the report is bounded and never claims EPUB conformance. The
  rule catalog is validated against EPUBCheck 5.4.0 runs on a committed
  fixture corpus (`doc/epub-diagnostics.md`).
- DjVu hidden-text zones decoded with the reference grammar: the full
  page/column/region/paragraph/line/word/character tree keeps the stored
  bottom-left coordinates and byte ranges, and every zone binds to canonical
  UTF-16 ranges of the rendered page text under the stable `djvu.hidden-text`
  extraction profile. `DjvuBook.pageStructureAt` exposes the structure; a
  depth bound replaces the type-ordering rule because real encoders nest out
  of order. `tool/djvu_spatial_compare.dart` matches all five corpus fixtures
  against `djvused` 3.5.29 (32,684 zone records, 51,203 leaf texts).
- A minimal shared spatial contract in foundation: top-left rectangles, the
  ALTO unit vocabulary (pixel, `mm10`, `inch1200`), region/line/word zones
  with UTF-16 ranges and optional OCR confidence, depth-first pages with
  provenance, and range lookups.
- ALTO OCR import (`lib/alto.dart`): namespaces v2/v3/v4, Description
  provenance (OCR software, source image), pages, text and non-text blocks
  (composed blocks descend), lines, and strings with confidence. Coordinates
  stay in the declared unit; conversion happens only through a verified
  scale (declared dpi or agreeing page dimensions) and physical units
  without evidence refuse typed. `bindAltoToSnapshot` maps ALTO words onto a
  host-provided canonical snapshot with a reading cursor: repeated quotes
  report ambiguity with bounded candidate lists, absent words report
  missing, and a projection budget stops quadratic work. The binding keeps
  the target's identity tuple, the OCR origin, software, and confidence.
- The spatial public path: DjVu hidden text indexes under its own profile
  (`BookSearchIndex.build` handles DjvuBook), so index hits, zone lookups,
  and durable anchors address one text space; profile or identity swaps
  invalidate reuse. Browser workers serve `spatial.djvuPage` and
  `spatial.altoBind` against the resident book, and the DjVu wire payload
  carries each page's encoded hidden-text chunk so wire-resident books
  rebuild their structures.
- Solid RAR 5 comic chains: the per-entry solid bit continues a
  dictionary carried across entries (window, Huffman tables, recent
  offsets, filters), with each entry keeping its own framed block
  stream, dictionary growth on continuation, and filter offsets that
  restart per entry. The eager parse and every session drive the same
  decoder, byte-identical against the rardecode (v2.4.5) and libarchive
  (3.7.4) oracles on a pinned fixture corpus with real cross-entry
  history. The archive-level solid flag alone leaves entries
  independent, matching the reference decoder.


- Structured PDF pages with glyph-derived words, lines, blocks, columns,
  simple tables, page geometry, and stable source anchors. Source anchors
  map to canonical text across reopening and eager/progressive mode changes;
  canonical snapshots retain each mode's extraction profile and reflow plan.
  Structures are available through eager parsing, sessions, and browser workers.
- A common text contract with publication revisions, section occurrences,
  extraction profiles, UTF-16 ranges, deterministic SHA-256 revisions, and
  validated snapshot/range codecs.
- Optional per-publication indexed search with BM25+ ranking, exact, prefix,
  and bounded fuzzy queries. Incremental construction reports coverage and
  supports cancellation. Results preserve original UTF-16 ranges and stable
  ordering. Existing `Book.search` behavior is unchanged.
- Search-index export/import for eager books and progressive sessions,
  including PDF. Reuse verifies destination text, reading order, and extraction
  profile. PDF indexes reopen within the same extraction mode; switching modes
  requires rebuilding. Structurally imported indexes require live text
  verification before querying.
- Durable annotation anchors with publication identity, revision, occurrence,
  quote/context evidence, a versioned codec, verified reuse, and explicit
  migration. Resolution reports ambiguity, missing targets, incompatible
  revisions, and unsupported cases. The W3C adapter supports TextQuoteSelector
  and TextPositionSelector with code point/UTF-16 conversion. Existing v1
  annotation and locator codecs remain unchanged.
- Compressed RAR 5 comic entries using algorithm version 0,
  methods 1-5, delta/E8/E8-E9/ARM filters, UTF-8 names, and dictionaries through
  64 MiB. Eager and progressive readers share the decoder and container walk.
- JPEG 2000 Part 1 decoding for PDF `JPXDecode`, including ASCII85 filter
  chains: J2K/JP2, unsigned 8-bit grayscale/RGB, reversible 5/3 and irreversible
  9/7 wavelets, LRCP/RLCP, single/multiple tiles, RCT/ICT, SOP/EPH markers,
  segmentation symbols, custom precincts, and multiple quality layers.
- Licensed fixtures, independent reference comparators, focused malformed-input
  coverage, VM/browser parity tests, and benchmarks for the new features.
  Reference tools remain development dependencies only.

### Changed

- TIFF `FillOrder` 2 now fails typed under every codec; only the CCITT path
  checked it before, and sub-byte samples under other codecs would have been
  read bit-reversed. Transposed Orientation 5-8 and JPEG tiles fail typed.
- Progressive CBR sessions decode solid chains sequentially at open
  (the page sniff walks the chain — the documented open cost) and serve
  backward access by replaying from bounded dictionary checkpoints
  under a cumulative 512 MiB replay budget, charged before the work.
  Each session owns its decoder and checkpoints; a failed decode
  poisons forward continuation until a checkpoint restore, and
  reopening resets the budgets. Session CRC verification, including
  declared zeros, is unchanged.
- Progressive MOBI and AZW3/KF8 sessions. `BookSession.open` and
  `BookSession.openFile` now cover MOBI 6, AZW3/KF8 and joint files with the
  same structure-first contract as EPUB, comic and PDF sessions: complete
  navigation, metadata, bounded cover, and an explicit reading order while
  content materializes per section or part on demand. MOBI 6 sections tile
  the single HTML stream at the table-of-contents anchors (pagebreak split
  when no TOC exists) and reproduce the eager document's canonical text
  exactly; KF8 parts assemble one at a time through the shared per-part
  builder and resolve `kindle:pos:fid` links over bounded windows.
- A session metrics channel (`BookSession.metrics`, the `sessionMetrics`
  transport op) reporting container reads, decode work, and materialized
  content, so progressive delivery is measurable rather than asserted.
  Session headers cross the browser wire as structure plus record 0.
- Progressive EPUB and CBZ sessions over host-owned byte sources:
  `BookSession.openSource` plus the public `UnsealByteSource` contract
  (length, revision identity, exact `readRange`, close). Unseal orders
  the ranges — an end-of-central-directory tail scan, bounded central
  directory windows, then one local header and one compressed payload
  per entry — while the host keeps HTTP, authentication, storage, and
  retries. Reads carry the revision captured at open and fail typed
  (`ByteSourceShortReadException`, `ByteSourceLongReadException`,
  `ByteSourceReadException`, `ByteSourceRevisionChangedException`,
  `ByteSourceLimitExceededException`, `ByteSourceClosedException`)
  when the host answer or the source state breaks the contract.
  `SessionPolicy` gains `rangeRequestsInFlight`,
  `rangeBytesInFlight`, and `rangeRequestBytes` budgets: extra
  requests queue (backpressure) and over-cap requests fail typed
  instead of downloading the container. VM sessions run through a
  versioned `byteSource.v1` isolate bridge; browser sessions through
  the same protocol over the configured Web Worker, with per-session
  isolation so concurrent books never exchange bytes. Bytes, file,
  and local CBR/PDF opens are unchanged.

### Fixed

- PDF byte-source sessions keep coverage as offsets without retaining fetched
  payloads, bound each parser working set before fetching, preserve missing-range
  control flow through optional-content recovery, and cancel queued operations.
- PAGE rejects foreign descendant namespaces and malformed alternative indexes;
  distinct OCR alternatives remain ambiguous through parent/child bindings,
  with every projection scan charged before execution.
- OPDS 2 rejects non-finite numbers and invalid calendar timestamps with typed
  failures, and recognizes query parameters after earlier URI-template expressions.
- TIFF orientation flips avoid an unbudgeted row copy; CCITT current/reference
  run buffers are fixed-size, reused and reserved before decoding.
- TIFF Predictor 2 on 16-bit samples accumulated bytes instead of 16-bit
  words and lost every carry; gray and RGB 16-bit pages with horizontal
  differencing now match libtiff (the previous `gray16-deflate-predictor.tif`
  golden pinned the wrong raster).
- TIFF modified Huffman (compression 2) dropped whole buffered bytes when
  aligning rows and failed on libtiff-written files; rows now align the way
  `Fax3DecodeRLE` does.
- TIFF Group 4 read `T6Options` bit 1 as a row-alignment flag; it is the
  uncompressed-mode extension flag (bit 0 is reserved) and now fails typed.
- JPEG 2000 base-subset defects found by the precision corpus: COC markers
  were parsed with a non-existent SGcod section; QCD/QCC band tables were
  sized from the COD decomposition levels instead of the segment length and
  scalar-derived quantization ignored equation E-5; the 5/3 inverse lifting
  lacked the odd-start one- and two-sample cases and touched zero-length
  lines of empty resolutions; the 9/7 lifting missed the left mirror of the
  first odd-start high-pass sample and never wrote back a trailing
  high-pass sample; and tile origins were not clamped to the image origin.
- DjVu spatial regions follow their own native subtree, including sibling
  paragraphs without explicit regions and a return from nested regions.
- Mixed literal Unicode and percent-escaped EPUB paths resolve correctly.
  Diagnostic XML is bounded before building its tree.
- ALTO rejects non-finite or negative geometry with typed errors and cannot
  report a repeated OCR quote as unique after truncating its candidate scan.
- RAR solid random access handles stored intermediate entries and verifies
  every dependency checksum before reusing decoder state.
- MOBI session chapters preserve image and cross-section link targets;
  cancellation also works when a host byte source runs inline.
- PDF text matrices and text rise now compose correctly with the current
  transformation matrix. Word geometry matches the pinned PdfPig oracle on
  the real-book corpus without changing canonical text.
- The aligned-column table fallback rejects excessive candidate columns
  instead of reporting dense prose as a wide table.
- Annotation capture preserves application identifiers. Whitespace-only
  selections migrate without leaking parser errors. Exhausted search budgets
  cannot certify an incomplete candidate set, and unknown identity evidence
  cannot produce verified reuse.
- Text profiles keep immutable options and consistent equality/hash behavior.
- JPEG 2000 rejects unsupported calibrated/ICC color spaces and embedded-alpha
  declarations instead of emitting pixels with unverified color semantics.

### Behavior and limits

- RAR 5 validates header CRC-32 and declared data CRC-32, including zero.
  Split, encrypted, linked, unknown-size, unsupported-version, and
  oversized-dictionary entries fail with typed errors. RAR 4 is unchanged.
- JPEG 2000 remains a bounded subset. Unsupported coding styles, color models,
  alpha, profiles, and conflicting dimensions fail with typed PDF errors.
  Lossless samples match the OpenJPEG reference corpus exactly; lossy samples
  use the fixture manifest's declared tolerances.
- Applications continue to own persistence, networking, rendering, and OCR.
  The README documents the supported subsets and limits.

## 1.2.0 - October 16, 2026

### Added

- EPUB fixed-layout modeling: declared page viewports
  (`EpubBook.contentViewports`, `viewportForSpineIndex`) read from XHTML
  `<meta name="viewport">` declarations and standalone SVG geometry, spine
  `linear="no"` items (`nonLinearSpinePaths`, `spineItemIsLinear`), and
  effective per-spine-index rendition helpers (`layoutForSpineIndex`,
  `orientationForSpineIndex`, `spreadForSpineIndex`,
  `pageSpreadForSpineIndex`) on `EpubBook`.
- Standalone SVG content documents join the EPUB reading order and search as
  text content documents instead of bucketing as images.
- The browser worker wire carries the fixed-layout viewports, spine
  linearity, and spine idrefs of EPUB books.
- Progressive `BookSession` reads for EPUB, CBZ, CBR, and PDF, with a
  structure-only book header, on-demand resources and document text, search,
  statistics, progression, CFI operations, cancellation, and disposal.
  Sessions run in a resident VM isolate or browser worker, with per-session
  isolation and a byte-budgeted cache. File sessions read the source in the
  isolate; PDF sessions also expose original byte ranges and page text geometry.
- EPUB 3 rendition settings, page-list and landmarks navigation, and
  accessibility metadata in the package model.
- Typed book-opening results and typed failures for EPUB metadata updates.
- PDF page extraction diagnostics and comic page semantics for reader clients.
- Standalone Markdown, RTF, PalmDOC PDB, unencrypted eReader PDB, and Plucker
  PDB text parsing, each with format-specific public entry points.
- CHM reading with bounded LZX decompression, HTML topics, resources,
  hierarchical contents, Intel E8 restoration, and Windows-1251/1252/1256
  decoding selected by locale; Sony LRF reading with reflowed text, metadata,
  navigation, embedded images, and legacy headers through version 800.
- LRX2 plaintext metadata inspection, with protected book content rejected.
- DjVu visual pages with direct JPEG, JB2 masks, shared `Djbz` dictionaries
  referenced by `INCL`, progressive IW44 color and grayscale layers, and
  BG/FG/mask composition. Compressed `TXTz` hidden text becomes searchable
  content; `NAVM` bookmarks become navigation. File-based opens also resolve
  indirect documents from validated sibling components.
- TIFF and BigTIFF multi-page parsing with page dimensions, DPI, metadata,
  BMP output and self-contained JPEG-strip passthrough. Supported raster
  codecs include uncompressed, PackBits, LZW, Deflate/AdobeDeflate, and
  CCITT Group 3/4. Unsupported layouts and codecs fail with typed exceptions.
- KEPUB fixture validation through the existing EPUB parser, including an
  independently produced Standard Ebooks Kobo edition.
- eReader PML emphasis, headings, local links, PNG images, footnotes, and
  sidebars; Plucker inline formatting, links, headings, and 1/2/4-bit grayscale,
  8-bit system-palette, 4/8-bit custom-palette, and 16-bit RGB565 bitmaps.

### Behavior and limits

- `Unseal.read` and the existing eager APIs retain their full-book behavior.
  `BookSession` supports EPUB, CBZ, CBR, and PDF only; other formats throw
  `SessionUnsupportedFormatException`. Compressed CBR entries inflate during
  session opening; CBZ/CBR search returns no matches because pages contain no
  searchable text. Sessions do not perform OCR.
- Byte-based DjVu opens reject indirect documents. Use `Unseal.readFile`
  to resolve their sibling files on filesystem platforms. Shared dictionaries
  that inherit another dictionary and replacement visual codecs remain
  unsupported; `FGbz` palette recoloring is ignored.
- DjVu visual decoding is bounded at 2048 million cumulative pixels and
  1 GiB of raster bytes per book, with separate page and codec limits.
  TIFF/BigTIFF keeps a 128 MiB input limit, 1,024 pages, 256 million decoded
  pixels per book, and 128 MiB of decoded raster.

### Reliability and scope

- Added licensed or original fixtures, provenance, malformed-input tests,
  browser coverage, and format-specific size and decompression limits.
- The supported subset and remaining gaps for every new format are documented
  in the README. Pending extensions and validation gaps are collected in
  `doc/roadmap.md`.
- Added session parity, concurrency and cancellation tests, worker coverage,
  and deterministic fuzz cases for progressive PDF/comic sessions and scanned
  archives. DjVu text and selected raster pages are pinned against DjVuLibre;
  TIFF pixels are pinned against libtiff. Composed DjVu pages retain the
  documented hard-mask rendering differences.
- Corrected DjVu budget failure messages to report the current limits.
- Included maintained guides in the published package, removed completed
  campaign documents, and consolidated pending work in `doc/roadmap.md`.

## 1.1.0 - September 19, 2026

Dependency maintenance release. No public API changes.

### Changed

- Upgraded `archive` to `^4.3.0`, `koni_archive` to `^0.9.0`, and `xml` to
  `^7.0.1`, with the corresponding parser migrations.
- Shortened the package description to meet pub.dev conventions.

### Safety and reliability

- ZIP containers with a missing or unreadable central directory now fail with
  `InvalidBookException` instead of decoding to an empty archive.
- ZIP-bomb guards keep bounding decompression during inflation on the
  `archive` 4 streaming API, and explicit directory records in book
  containers keep parsing as empty entries.

## 1.0.0 - September 19, 2026

Initial release of Unseal, a pure-Dart library for parsing ebooks and
producing format-neutral reading data.

### Highlights

- Parses EPUB 2/3, MOBI 6, AZW3/KF8, FB2/FBZ, TXT/TXTZ, HTML/HTMLZ,
  DOCX, ODT, AZW4, CBZ, CBR, CB7, CBC, and PDF.
- Exposes a common `Book` model with metadata, cover data, files, reading
  order, navigation, statistics, and original archive information.
- Provides metadata-only reads, automatic format detection, full-text search,
  locators, EPUB CFI operations, reading progression, portable annotations,
  OPDS parsing, and web-worker support.
- Parses EPUB media-overlay timing, preserves right-to-left progression, reads
  sidecar OPF metadata, and supports MOBI/KF8 navigation, PDF extraction and
  reflow, and comic page ordering.
- Rejects unsupported DRM and encrypted inputs; supported password-protected
  PDFs can be opened with the correct password.

### Safety and reliability

- Uses typed exceptions for empty, malformed, encrypted, and unsupported
  input.
- Bounds ZIP expansion, entry sizes, compression ratios, PDF object nesting,
  and FB2 XML depth to make hostile input fail predictably.
- Rejects symbolic links and unsupported archive compression methods.
- Includes focused regression coverage for malformed and adversarial input on
  the Dart VM and in browsers.
