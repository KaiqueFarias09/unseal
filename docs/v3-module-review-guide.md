# Review the eLivre v3 modules

Use this guide to review eLivre 3.3.0, eLivre Viewer 0.2.0, and eLivre Viewer Narration 0.1.0 before publication. The checkboxes record a human review. They do not duplicate the automated test suite.

The three packages have different jobs:

```text
e_livre
  parses bytes and exposes format-neutral book data
      |
      v
e_livre_viewer
  renders that data and owns reader interaction
      |
      v
e_livre_viewer_narration
  adds optional TTS, recorded audio, and media controls
```

Review them in that order. A viewer defect can originate in parsing, but the parser must not depend on Flutter or on either downstream package.

## Record the review

For each module:

1. Read the public entrypoint and the first implementation file listed under **Start here**.
2. Follow one representative input through the module.
3. Run the focused tests.
4. Check the public behavior, failure behavior, and resource limits.
5. Mark a checkbox only after the code and the test agree.

Before release, every unchecked item needs one of three outcomes: a fix, a documented limitation, or removal from the advertised contract.

## Understand the common book model

### Foundation

The foundation is the vocabulary shared by every format. `Book` describes files, metadata, cover data, navigation, reading order, and archive inventory. `DocumentBook` is the common result for formats converted to reflowable HTML. Foundation code must not know which format produced the data.

Start here:

- `lib/src/foundation/entities/book/book.dart`
- `lib/src/foundation/entities/book/document_book.dart`
- `lib/src/foundation/entities/book/files.dart`
- `lib/src/foundation/entities/book/reading_order_item.dart`
- `lib/src/foundation/entities/book_metadata.dart`
- `lib/src/foundation/entities/navigation/navigation.dart`
- `lib/src/foundation/entities/file/book_file.dart`

Supporting modules:

- `foundation/archive` normalizes archive paths and inventories entries.
- `foundation/text` decodes text and defines the canonical text seen by search and locators.
- `foundation/metadata` merges metadata and applies filename fallbacks.
- `foundation/images` identifies images and reads their dimensions.
- `foundation/navigation` derives navigation from HTML headings.
- `foundation/language` recognizes right-to-left language tags.

Review checklist:

- [ ] Every supported parser can express its output without a format-specific condition in `Book`.
- [ ] `readingOrder` resolves only to files present in `Files`.
- [ ] Metadata merge precedence is documented and covered by `metadata_utils_test.dart`.
- [ ] Archive paths reject traversal and use one normalized separator convention.
- [ ] `documentTextOf` produces the character space used by search, locators, highlights, and PDF reflow.
- [ ] Foundation imports no file from `features`, `platform`, Viewer, or Narration.
- [ ] Public value objects have stable equality, serialization, and nullability semantics.

Focused tests:

```text
test/tests/core/
test/tests/core/reading_order_test.dart
```

### Detection and dispatch

Detection examines bytes instead of trusting a filename. This matters because ZIP is only a container signature. EPUB, FB2 archives, DOCX, ODT, HTMLZ, TXTZ, CBZ, and CBC can all start with `PK`. `BookDispatch` first identifies the container family and then inspects the entries to choose the parser.

Start here:

- `lib/src/features/detection/detect_format.dart`
- `lib/src/features/detection/refine_mobi_format.dart`
- `lib/src/features/reading/book_dispatch.dart`
- `lib/src/platform/book_reader.dart`

Review checklist:

- [ ] Every advertised format reaches the correct parser through `BookReader.openFromBytes`.
- [ ] ZIP refinement checks EPUB before the generic comic fallback.
- [ ] Empty, unknown, Topaz, KFX, and RTF inputs fail with typed exceptions.
- [ ] PDF detection accepts only the bounded preamble documented in the public contract.
- [ ] UTF-16 FB2 and text signatures follow the same decoding rules as their parsers.
- [ ] Async-only CB7 and CBC routes never enter a synchronous parser silently.
- [ ] Metadata-only dispatch avoids full extraction where the format permits it.

Focused tests:

```text
test/tests/core/detection_test.dart
test/tests/reading/format_dispatch_test.dart
test/public_format_entrypoints_test.dart
```

## Review each format adapter

### EPUB 2 and EPUB 3

An EPUB is a ZIP package. `META-INF/container.xml` points to an OPF package document. The OPF defines metadata, a manifest of resources, and a spine that gives reading order. Navigation can come from an EPUB 3 navigation document or an older NCX file.

Media overlays belong inside the EPUB module because EPUB package metadata connects an XHTML spine item to a SMIL document. The parser resolves that relationship and returns timing data. Narration later decides how to play it.

Start here:

- `lib/epub.dart`
- `lib/src/features/epub/parse_epub_book.dart`
- `lib/src/features/epub/container/epub_root_file.dart`
- `lib/src/features/epub/package/parse_epub_package.dart`
- `lib/src/features/epub/content/epub_files.dart`
- `lib/src/features/epub/navigation/epub_navigation.dart`
- `lib/src/features/epub/encryption/epub_encryption.dart`
- `lib/src/features/epub/media_overlays/parse_media_overlay.dart`
- `lib/src/features/epub/media_overlays/media_overlay.dart`

Review checklist:

- [ ] Rootfile discovery handles valid `container.xml`, multiple rootfiles, and recovery by scanning usable OPF entries.
- [ ] OPF 2 and OPF 3 metadata map to the common `BookMetadata` fields.
- [ ] Manifest paths resolve relative to the selected OPF, including encoded paths.
- [ ] Spine order matches `readingOrder`, and missing manifest references fail or recover deliberately.
- [ ] EPUB 3 navigation, NCX navigation, guide references, and empty navigation behave as documented.
- [ ] Cover selection follows EPUB 3 properties, EPUB 2 metadata, guide references, and fallback order.
- [ ] IDPF and Adobe font obfuscation use the correct publication identifier.
- [ ] SMIL clocks, text fragments, audio paths, clip bounds, and spine associations survive parsing.
- [ ] Metadata-only reads inflate only the OPF and required cover data.
- [ ] The public `epub.dart` entrypoint exposes every type required to use its results.

Focused tests:

```text
test/tests/epub/
test/media_overlays_test.dart
test/tests/cfi/
```

### MOBI 6 and AZW3, also called KF8

MOBI uses the Palm Database container. The PDB header locates records. The MOBI and EXTH headers describe text encoding, metadata, resources, DRM, and the boundary between legacy MOBI 6 and KF8 content. Text records can use PalmDOC or HUFF/CDIC compression.

MOBI 6 often contains one HTML stream with `filepos` links. KF8 reconstructs HTML from skeleton and fragment records, then uses FDST flow information for CSS and other resources. A joint file can contain both generations, so the reader must choose the KF8 half without corrupting record offsets.

Start here:

- `lib/mobi.dart`
- `lib/src/features/mobi/parse_mobi_book.dart`
- `lib/src/features/mobi/header/`
- `lib/src/features/mobi/compression/`
- `lib/src/features/mobi/reader/mobi_container.dart`
- `lib/src/features/mobi/reader/mobi_text.dart`
- `lib/src/features/mobi/reader/mobi8_structure.dart`
- `lib/src/features/mobi/reader/mobi8_reader.dart`
- `lib/src/features/mobi/reader/mobi6_markup.dart`
- `lib/src/features/mobi/reader/mobi8_markup.dart`
- `lib/src/features/mobi/reader/mobi8_resources.dart`
- `lib/src/features/mobi/index/`

Review checklist:

- [ ] PDB record offsets are ordered, in bounds, and validated before slicing.
- [ ] PalmDOC and HUFF/CDIC decompression reject malformed back-references and excessive output.
- [ ] EXTH metadata is optional where real books omit or damage recoverable records.
- [ ] DRM records produce `DrmProtectedException` instead of unreadable output.
- [ ] Joint MOBI files select the intended KF8 boundary record.
- [ ] MOBI 6 `filepos` links and chapter splits use normalized offsets.
- [ ] KF8 skeleton, fragment, and FDST reconstruction preserves reading order.
- [ ] CONT and CRES resources, fonts, CSS, SVG, and cover records receive stable paths.
- [ ] NCX and INDX parsing produces deterministic navigation.
- [ ] Metadata-only reads avoid complete markup reconstruction.

Focused tests:

```text
test/tests/mobi/
```

### AZW4

AZW4 is a PalmDB or MOBI envelope containing a PDF payload. It is not another reflow format. The adapter validates the wrapper, rejects DRM, joins PDF records, and delegates the result to the PDF parser while preserving `BookFormat.azw4`.

Start here:

- `lib/azw4.dart`
- `lib/src/features/azw4/container/azw4_pdf_extractor.dart`
- `lib/src/features/azw4/parse_azw4_book.dart`
- the PDF module

Review checklist:

- [ ] The PalmDB record table is valid before records are joined.
- [ ] Split PDF signatures across record boundaries are detected.
- [ ] Non-PDF and DRM-protected payloads fail with typed exceptions.
- [ ] PDF password, metadata, page count, reflow, and original bytes survive delegation.
- [ ] The result reports AZW4 without duplicating the PDF implementation.

Focused tests:

```text
test/tests/azw4/azw4_test.dart
test/tests/pdf/
```

### FB2 and FBZ

FictionBook 2 is XML. Metadata lives in `<description>`, content in one or more `<body>` elements, and images in base64 `<binary>` elements. FBZ is the same XML inside ZIP. Notes commonly live in a separate body and use internal links.

Start here:

- `lib/fb2.dart`
- `lib/src/features/fb2/parse_fb2_book.dart`
- `lib/src/features/fb2/container/fb2_document.dart`
- `lib/src/features/fb2/metadata/fb2_metadata.dart`
- `lib/src/features/fb2/resources/fb2_resources.dart`
- `lib/src/features/fb2/rendering/fb2_html_renderer.dart`

Review checklist:

- [ ] BOMs, declared encodings, comments, processing instructions, and XML namespaces are accepted where valid.
- [ ] Metadata-only reads stop after the description and required cover binary.
- [ ] Base64 images have stable extensions, paths, and cover selection.
- [ ] Multiple bodies, notes, sections, poems, tables, links, and empty sections convert deliberately.
- [ ] Embedded and named styles remain scoped to the produced HTML.
- [ ] Section navigation points to files and fragments that exist.
- [ ] Plain FB2 and zipped FB2 produce equivalent book semantics.

Focused tests:

```text
test/tests/fb2/
```

### PDF

The PDF module produces reading data. It is not a general-purpose renderer. It reads cross-reference tables or streams, resolves indirect objects and page trees, decodes content streams and fonts, extracts text and supported images, opens supported encrypted documents, and builds one canonical reflow section per page. The original bytes remain available for facsimile viewing.

Some large files are intentionally cohesive. `pdf_encodings.dart` and `pdf_standard_widths.dart` are lookup data. JBIG2, MMR, Huffman, and CCITT files implement bounded codecs whose state is easier to verify in one place than across thin wrappers.

Start here:

- `lib/pdf.dart`
- `lib/src/features/pdf/parse_pdf_book.dart`
- `lib/src/features/pdf/header/pdf_document.dart`
- `lib/src/features/pdf/header/pdf_object_parser.dart`
- `lib/src/features/pdf/reader/pdf_page_tree.dart`
- `lib/src/features/pdf/reader/pdf_content_stream.dart`
- `lib/src/features/pdf/reader/pdf_font.dart`
- `lib/src/features/pdf/security/`
- `lib/src/features/pdf/codec/`
- `lib/src/features/pdf/reflow/pdf_reflow.dart`

Review checklist:

- [ ] Traditional xref tables, xref streams, object streams, trailers, and incremental updates resolve correctly.
- [ ] Object and stream bounds prevent unbounded reads and decompression.
- [ ] Page inheritance, rotation, media boxes, crop boxes, and resource dictionaries resolve through the page tree.
- [ ] Text operators, spacing, transforms, font encodings, ToUnicode maps, and fallback widths preserve canonical text order.
- [ ] Reflow text uses the same character offsets as search, locators, highlights, and the Viewer text layer.
- [ ] JPEG, CCITT, and JBIG2 extraction stays within documented resource limits.
- [ ] Standard security revisions 2 through 6 accept correct passwords and reject incorrect passwords.
- [ ] Algorithm 2A remains isolated behind its security interface and passes the crypto matrix.
- [ ] Metadata, outline destinations, and page anchors resolve to existing pages.
- [ ] Unsupported graphics, forms, scripts, and malformed constructs fail or degrade as documented.
- [ ] Lookup-data files are generated or provenance-documented and are not split for line-count compliance.

Focused tests:

```text
test/tests/pdf/
test/tests/corpus/book_corpus_test.dart
tool/pdf_parity.dart
```

### CBZ and CBR

Comic books are ordered image archives. CBZ uses ZIP. CBR uses RAR. `ComicInfo.xml` can supply title, creators, series data, and page metadata. Natural filename order matters because lexical sorting puts `10.jpg` before `2.jpg`.

Start here:

- `lib/comic.dart`
- `lib/src/features/comic/parse_comic_book.dart`
- `lib/src/features/comic/metadata/comic_info.dart`
- `lib/src/features/comic/archive/rar_reader.dart`
- `lib/src/features/comic/archive/rar4_decoder.dart`

Review checklist:

- [ ] ZIP and RAR inputs reject traversal paths and invalid entry bounds.
- [ ] Natural sorting remains deterministic across directories and mixed numeric names.
- [ ] `ComicInfo.xml` metadata and page declarations do not reorder or hide valid pages incorrectly.
- [ ] The first readable page becomes the cover when metadata does not select another page.
- [ ] RAR 4 stored and ordinary non-solid method-29 entries pass real fixtures.
- [ ] RAR 5 stored entries with extra header areas remain supported.
- [ ] Solid archives, VM filters, PPMd, encryption, and unsupported methods fail with the documented exception.
- [ ] Image type sniffing does not trust a misleading extension.

Focused tests:

```text
test/tests/comic/
test/tests/corpus/book_corpus_test.dart
```

### CB7 and CBC

CB7 is a comic archive stored in 7-Zip. CBC is a Calibre collection ZIP whose top-level `comics.txt` lists nested comic files and optional titles. These parsers remain separate from CBZ and CBR because 7-Zip extraction is asynchronous and enforces a per-entry output budget.

Start here:

- `lib/comic7.dart`
- `lib/src/features/comic7/parse_comic7_book.dart`
- `lib/src/features/comic7/exceptions/`
- `BookDispatch` async routes in `lib/src/features/reading/book_dispatch.dart`

Review checklist:

- [ ] CB7 accepts supported image entries and enforces the decompression budget.
- [ ] Natural page order and `ComicInfo.xml` match CBZ and CBR behavior.
- [ ] CBC reads `comics.txt` in declaration order and resolves only safe nested paths.
- [ ] Nested CBZ, CBR, and CB7 failures identify the member that failed.
- [ ] CBC page flattening and title behavior match the documented common `ComicBook` model.
- [ ] Sync entrypoints explain that callers must use the async public interface.

Focused tests:

```text
test/tests/comic7/comic7_test.dart
test/tests/reading/format_dispatch_test.dart
```

### TXT and TXTZ

TXT has no universal metadata or structure. eLivre decodes common Unicode encodings, recognizes limited text headers, preserves paragraphs, and emits safe XHTML. TXTZ is a ZIP convention that can hold multiple text files, resources, and an optional Calibre-style `metadata.opf` sidecar.

Start here:

- `lib/txt.dart`
- `lib/src/features/txt/parse_txt_book.dart`
- `lib/src/features/txt/text/txt_document.dart`
- `lib/src/features/txt/archive/txtz_archive.dart`

Review checklist:

- [ ] UTF-8, UTF-16, BOM handling, line endings, and invalid byte replacement are deterministic.
- [ ] Plain text becomes escaped XHTML without changing paragraph order.
- [ ] Markdown and Textile recognition remains limited to the advertised subset.
- [ ] TXTZ text files use natural order and resource paths remain safe.
- [ ] `metadata.opf` metadata, manifest hints, and cover selection merge correctly.
- [ ] Metadata-only reads avoid rendering every text section.
- [ ] Very large lines and files have explicit memory behavior.

Focused tests:

```text
test/tests/txt/txt_test.dart
test/tests/core/plain_text_test.dart
```

### HTML and HTMLZ

Standalone HTML preserves the source document after encoding and metadata normalization. HTMLZ follows Calibre's top-level convention. It selects one top-level `index.html`, `index.xhtml`, or `index.htm`, reads an optional OPF sidecar, and retains the remaining files as resources.

Start here:

- `lib/html.dart`
- `lib/src/features/html/parse_html_book.dart`
- `lib/src/features/html/parsing/html_document.dart`
- `lib/src/features/html/metadata/html_metadata.dart`

Review checklist:

- [ ] HTML, HTM, and XHTML encodings and MIME variants parse consistently.
- [ ] Head metadata and heading navigation preserve document order.
- [ ] HTMLZ selects only a top-level HTML spine file using the documented preference.
- [ ] Optional malformed OPF metadata does not make readable HTML unusable.
- [ ] Relative cover and resource paths resolve from the OPF location.
- [ ] Other HTML files remain resources instead of silently entering the reading order.
- [ ] The Viewer disables book-authored JavaScript by default because parsing alone is not a security sandbox.

Focused tests:

```text
test/tests/html/html_test.dart
test/tests/reading/nav_content_test.dart
```

### DOCX

DOCX is a ZIP package of WordprocessingML parts. `word/document.xml` contains the main document. Relationship files map IDs to hyperlinks and embedded resources. Styles and numbering live in separate XML parts. eLivre converts semantic document structure to XHTML rather than reproducing Word's page layout.

Start here:

- `lib/docx.dart`
- `lib/src/features/docx/parse_docx_book.dart`
- `lib/src/features/docx/container/`
- `lib/src/features/docx/metadata/docx_metadata.dart`
- `lib/src/features/docx/styles/docx_styles.dart`
- `lib/src/features/docx/rendering/docx_renderer.dart`
- `lib/src/features/docx/resources/docx_resources.dart`

Review checklist:

- [ ] Required content types, document parts, and relationship targets are validated.
- [ ] Core properties map to the common metadata model.
- [ ] Paragraphs, runs, headings, lists, tables, breaks, links, and images produce valid XHTML.
- [ ] Style inheritance and numbering have deterministic fallbacks.
- [ ] External relationships cannot become local archive reads.
- [ ] Unsupported footnotes, tracked changes, equations, charts, and layout features degrade as documented.
- [ ] Metadata-only reads still validate the required document part.

Focused tests:

```text
test/tests/docx/docx_test.dart
```

### ODT

ODT is a ZIP package built from OpenDocument XML. `content.xml` contains document structure. `styles.xml` and automatic styles describe formatting. `meta.xml` contains document metadata. As with DOCX, eLivre preserves semantic structure and not exact page layout.

Start here:

- `lib/odt.dart`
- `lib/src/features/odt/parse_odt_book.dart`
- `lib/src/features/odt/container/odt_package.dart`
- `lib/src/features/odt/metadata/odt_metadata.dart`
- `lib/src/features/odt/styles/odt_styles.dart`
- `lib/src/features/odt/rendering/odt_renderer.dart`
- `lib/src/features/odt/resources/odt_resources.dart`

Review checklist:

- [ ] The package validates `content.xml` and handles optional metadata and styles parts.
- [ ] Paragraphs, headings, spans, links, lists, tables, and images produce valid XHTML.
- [ ] Named and automatic styles resolve without leaking format types into foundation.
- [ ] Cover, metadata, navigation, and reading order use the common model.
- [ ] Unsupported fields, tracked changes, drawings, and exact page layout degrade as documented.
- [ ] Empty or malformed packages raise the ODT exception family.

Focused tests:

```text
test/tests/odt/odt_test.dart
```

## Review the format-neutral capabilities

### Search

Search compiles the user's query once, then applies it to the canonical text of each reading-order section. Exact, contains, whole-word, regular-expression, and proximity modes share result and truncation rules. Search offsets must remain usable by the Viewer.

Start here:

- `lib/src/features/search/book_search.dart`
- `lib/src/features/search/query_compiler.dart`
- `lib/src/features/search/entities/`
- `lib/src/foundation/text/canonical_document_text.dart`

Review checklist:

- [ ] Every search mode documents case, whitespace, hyphenation, and Unicode behavior.
- [ ] Invalid regex and proximity queries fail with `FormatException`.
- [ ] `maxMatches`, snippets, and truncation remain deterministic.
- [ ] Match offsets address canonical text, not raw HTML.
- [ ] Worker and direct search return equivalent results.

Focused tests:

```text
test/public_search_api_test.dart
test/tests/core/book_search_test.dart
test/web/book_search_unicode_test.dart
```

### EPUB CFI

An EPUB Canonical Fragment Identifier identifies a location inside an EPUB document through package and DOM steps. The parser preserves the CFI syntax. The resolver maps it to eLivre's section and canonical-text coordinates. Assertions and ranges help recover the intended location after small document changes.

Start here:

- `lib/src/features/cfi/epub_cfi.dart`
- `lib/src/features/cfi/epub_cfi_document.dart`
- `lib/src/features/cfi/epub_cfi_resolver.dart`

Review checklist:

- [ ] Point and range CFIs parse and serialize without semantic change.
- [ ] Escapes, indirection, text offsets, element assertions, and side bias are bounded and validated.
- [ ] Package steps resolve against spine order.
- [ ] DOM steps and text assertions map to canonical-text offsets.
- [ ] Invalid or stale CFIs fail or recover according to one documented rule.

Focused tests:

```text
test/tests/cfi/
```

### Locators

Locators give clients a portable position without exposing one format's internal representation. The hierarchy includes text quotes, EPUB CFIs, pages, and progression. Fuzzy relocation uses surrounding text when an exact offset no longer matches.

Start here:

- `lib/src/features/locators/book_locator.dart`
- `lib/src/features/locators/locator_codec.dart`
- `lib/src/features/locators/fuzzy_relocation.dart`
- `lib/src/features/locators/search_locator.dart`

Review checklist:

- [ ] Every locator variant round-trips through the codec.
- [ ] Versioned payloads reject unknown required fields safely.
- [ ] Search hits convert to locators without changing character offsets.
- [ ] Fuzzy relocation uses bounded context and deterministic tie-breaking.
- [ ] Page locators remain valid for comics and both PDF modes.

Focused tests:

```text
test/tests/locators/
```

### Portable annotations

The base package owns portable bookmark and highlight records, their codec, and merge behavior. It does not own viewer UI state. This lets annotations survive storage, synchronization, or a different reader implementation.

Start here:

- `lib/src/features/annotations/bookmark_record.dart`
- `lib/src/features/annotations/highlight_record.dart`
- `lib/src/features/annotations/annotation_codec.dart`
- `lib/src/features/annotations/annotation_merge.dart`

Review checklist:

- [ ] Current and legacy payloads decode with documented defaults.
- [ ] Stable identifiers, timestamps, locator data, colors, decorations, and notes round-trip.
- [ ] Merge rules are deterministic for additions, edits, deletions, and equal timestamps.
- [ ] Invalid records cannot corrupt the whole imported collection.
- [ ] The base records contain no Flutter or Viewer types.

Focused tests:

```text
test/tests/annotations/
```

### Reading progression and navigation resolution

This module maps navigation targets to reading-order sections and computes progression. It exists outside the Viewer because headless clients also need stable positions.

Start here:

- `lib/src/features/reading/book_progression.dart`
- `lib/src/features/reading/nav_resolution.dart`

Review checklist:

- [ ] Progression clamps and handles empty books, zero-length sections, and the final position.
- [ ] Encoded paths and fragments resolve against the correct content file.
- [ ] EPUB anchors map to canonical-text offsets when possible.
- [ ] MOBI `filepos` and page-like destinations use explicit fallback behavior.

Focused tests:

```text
test/tests/reading/book_progression_test.dart
test/tests/reading/nav_resolution_test.dart
test/tests/reading/nav_content_test.dart
```

### OPDS

OPDS is an Atom-based publication catalog format. This module parses feeds, entries, metadata, links, images, and acquisition relations. It does not download or open books.

Start here:

- `lib/src/features/opds/opds_feed.dart`

Review checklist:

- [ ] Atom and OPDS namespaces, relative URLs, and acquisition relations parse correctly.
- [ ] Missing optional metadata does not discard otherwise useful entries.
- [ ] Feed parsing stays separate from networking and download policy.
- [ ] Public models have stable equality and serialization expectations.

Focused tests:

```text
test/tests/opds/opds_feed_test.dart
```

### Calibre metadata databases

Calibre stores library metadata in SQLite. This module reads the database and returns library records. It is adjacent to parsing because it describes a collection, not a book's byte format.

Start here:

- `lib/src/features/calibre/calibre_database.dart`
- `lib/src/features/calibre/sqlite_database.dart`
- `lib/src/features/calibre/entities/calibre_book.dart`

Review checklist:

- [ ] SQLite page size, schema, tables, records, varints, and text encodings are validated.
- [ ] Missing optional Calibre tables or columns have documented behavior.
- [ ] Queries cannot read outside the supplied database bytes.
- [ ] Returned paths and format names map cleanly to `BookReader` inputs.

Focused tests:

```text
test/tests/calibre/calibre_database_test.dart
```

### Platform and worker adapters

`BookDispatch` owns parser choice. `BookReader` owns the public execution interface. Platform adapters decide whether work runs directly, in an isolate, or in a web worker. This direction keeps the parser independent of execution technology.

Start here:

- `lib/src/platform/book_reader.dart`
- `lib/src/platform/worker_book_reader.dart`
- `lib/src/platform/io/`
- `lib/src/platform/web/`
- `web/e_livre_worker.dart`

Review checklist:

- [ ] IO and web adapters preserve the same success and typed-error behavior.
- [ ] Worker messages encode every public book value required by the caller.
- [ ] Search and CFI worker operations match direct execution.
- [ ] Transferable byte handling does not retain avoidable copies.
- [ ] Worker shutdown, unknown operations, malformed messages, and stale requests are covered.
- [ ] Platform imports point toward Reading, never the reverse.

Focused tests:

```text
test/tests/web/
test/web/
```

## Review eLivre Viewer

The Viewer converts parsed book data into an interactive Flutter reader. Native platforms serve in-memory book files through a loopback server. Web uses same-origin browser resources. Rendering adapters hide WebView and iframe differences behind `ViewerEngine`.

### Controller and navigation

`ViewerController` is the public reader facade. It coordinates engines, serving, navigation, measurement, annotations, search, settings, and lifecycle. `NavigationCoordinator`, `PageMeasurementController`, and `AnnotationController` own state machines extracted from the facade.

Start here:

- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/controller/viewer_controller.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/controller/navigation_coordinator.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/controller/page_measurement_controller.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/annotations/annotation_controller.dart`

Review checklist:

- [ ] Opening, replacing, and closing a book release every engine, server, timer, stream, and listener once.
- [ ] Navigation history records TOC, links, footnotes, search, highlights, and CFI jumps consistently.
- [ ] Chapter transitions and spare-engine preloading cannot apply stale events.
- [ ] Page measurement uses one cache key for layout-affecting settings.
- [ ] Every annotation mutation emits persistence notification exactly once.
- [ ] The facade exposes no concrete platform adapter.
- [ ] Remaining facade code coordinates modules instead of reimplementing them.

Focused tests:

```text
test/viewer_controller_test.dart
test/navigation_coordinator_test.dart
test/page_measurement_controller_test.dart
test/annotation_controller_test.dart
test/elivre_view_lifecycle_test.dart
```

### Rendering engines and the bridge

`ViewerEngine` is the seam between reader behavior and a concrete WebView or iframe. `ViewerBridge` translates JavaScript events into typed Dart events.

Start here:

- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/rendering/api/viewer_engine.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/rendering/adapters/`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/rendering/composition/`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/bridge/viewer_bridge.dart`

Review checklist:

- [ ] Every production adapter satisfies the same load, command, event, and disposal interface.
- [ ] `FakeViewerEngine` tests the same interface used by production.
- [ ] Bridge decoding rejects malformed and unknown messages safely.
- [ ] Event ordering prevents old page events from overwriting the current position.
- [ ] Platform selection never imports an unavailable plugin on web.

Focused tests:

```text
test/bridge_test.dart
test/parity/
test/viewer_features_test.dart
```

### Book serving and HTML preparation

The serving module rewrites resource paths, injects viewer assets, applies the JavaScript policy, and exposes the book to the selected engine. The ordered HTML pipeline is intentionally one deep module because changing the order can undo a security or rendering step.

Start here:

- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_content.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_html_pipeline.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_resource_resolution.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_server.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_server_io.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_server_web.dart`

Review checklist:

- [ ] Resource rewriting handles encoded paths, fragments, CSS URLs, and missing assets.
- [ ] Book-authored scripts, inline handlers, and script URLs are disabled by default.
- [ ] Viewer-owned MathJax and PDF scripts are injected after book-script removal.
- [ ] Loopback responses use correct MIME types and cannot expose host files.
- [ ] Web resources stay same-origin and release blob URLs.
- [ ] Synthetic comic and PDF pages keep stable page identifiers.

Focused tests:

```text
test/book_content_test.dart
test/book_javascript_policy_test.dart
test/book_server_test.dart
```

### Viewer annotations and export

Viewer annotations add UI state and export projections to the portable base records. Querying, snapshot assembly, and HTML, Markdown, and plain-text rendering are separate modules so an export format does not need the entire controller.

Start here:

- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/annotations/viewer_annotations.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/annotations/annotation_query.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/annotations/export_document.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/annotations/export_snapshot.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/annotations/export_*.dart`

Review checklist:

- [ ] Base annotation import and export preserve every portable field.
- [ ] Filters and sorting produce stable results for equal values.
- [ ] Export snapshots depend on `ViewerExportSource`, not `ViewerController`.
- [ ] HTML export escapes user text and note content.
- [ ] Markdown and plain-text output handle empty chapters and missing quotes.
- [ ] Exported location links are optional and deterministic.

Focused tests:

```text
test/annotation_query_test.dart
test/export_test.dart
test/parity/annot_merge_test.dart
```

### Viewer search, PDF, MathJax, settings, and widgets

These modules adapt base-library data to presentation. Viewer search adds navigation marks. PDF adds reflow and facsimile mode selection. PDF.js renders original pages when available. MathJax handles book math after the JavaScript policy. Settings describe layout without owning application persistence. Widgets host the controller and user controls.

Start here:

- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/search/viewer_search.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/pdf/pdf_reading_mode.dart`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/pdfjs/`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/mathjax/`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/settings/`
- `/Volumes/SSD/Projects/e_livre_viewer/lib/src/widgets/`

Review checklist:

- [ ] Search result marks use base search offsets without recalculation drift.
- [ ] Reflow and facsimile PDF modes agree on page index and canonical text.
- [ ] PDF.js loading has explicit offline, failure, and retry behavior.
- [ ] MathJax loading does not enable book-authored scripts.
- [ ] Every layout-affecting setting invalidates the correct measurement cache.
- [ ] `ELivreView` transfers controller listeners safely across widget updates.
- [ ] Sheets and overlays remain presentation modules and contain no parser logic.

Focused tests:

```text
test/public_search_contract_test.dart
test/real_pdf_integration_test.dart
test/pdfjs_loader_test.dart
test/viewer_theme_test.dart
test/viewer_position_test.dart
```

## Review eLivre Viewer Narration

Narration is optional because its Flutter plugins and platform configuration are much heavier than parsing. `ViewerNarration` chooses recorded EPUB media overlays when available and otherwise uses device TTS. Source runners own the two playback strategies. Adapters own plugin calls. The media-session module maps playback to operating-system controls.

### Playback and sources

Start here:

- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/viewer_narration.dart`
- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/narration_controller.dart`
- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/narration_state.dart`
- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/sources/`

Review checklist:

- [ ] Starting chooses a valid media overlay first and TTS only when recorded audio is unavailable.
- [ ] Chapter changes, completion, pause, resume, seek, speed, and stop have one state transition each.
- [ ] TTS pause behavior, implemented as stop and sentence replay, remains documented.
- [ ] Recorded clip bounds and next-file selection follow the parsed SMIL order.
- [ ] Stale runner callbacks cannot mutate a later narration session.
- [ ] Closing releases the current runner and every adapter exactly once.
- [ ] Narration depends only on public eLivre and Viewer contracts.

### Adapters, media session, and presentation

Start here:

- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/speech_engine.dart`
- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/clip_player.dart`
- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/adapters/`
- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/media_session/narration_audio_handler.dart`
- `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/presentation/narration_bar.dart`

Review checklist:

- [ ] `SpeechEngine` and `ClipPlayer` expose behavior needed by both production and test adapters, and nothing more.
- [ ] TTS language, rate conversion, completion, cancellation, and engine errors map to narration state.
- [ ] Audio clips use inclusive and exclusive bounds consistently.
- [ ] Media-session state mirrors play, pause, stop, speed, position, and completion.
- [ ] Android and iOS setup instructions match the plugin versions in `pubspec.yaml`.
- [ ] `NarrationBar` owns presentation only and accepts the public controller interface.

Focused tests:

```text
test/viewer_narration_test.dart
test/flutter_tts_speech_engine_test.dart
test/public_entry_point_contract_test.dart
```

## Finish the v3 publication review

### Public contracts

- [ ] `lib/e_livre.dart` contains only format-neutral exports plus deliberate convenience exports.
- [ ] Every format entrypoint compiles by itself through `public_format_entrypoints_test.dart`.
- [ ] Viewer and Narration import only public entrypoints from upstream packages.
- [ ] The three READMEs use the same format names and version constraints.
- [ ] Breaking changes since the last published version appear in the changelog and migration notes.

### Compatibility evidence

- [ ] The fixture manifest records source, license, size, hash, and expected behavior for every third-party book.
- [ ] Every advertised format has at least one public-entrypoint test and one malformed-input test.
- [ ] EPUB, MOBI, PDF, FB2, and comics include representative real-writer fixtures.
- [ ] Known limitations appear in the README rather than only in tests.
- [ ] No test changes a real fixture merely to make a parser pass.

### Package publication

- [ ] `dart analyze` passes in eLivre and Narration.
- [ ] `flutter analyze` has no errors or warnings in Viewer.
- [ ] All VM, Chrome, and Flutter tests pass from clean checkouts.
- [ ] `dart pub publish --dry-run` passes for each publishable package.
- [ ] Local `dependency_overrides` are removed or excluded from the release checkout.
- [ ] Repository, issue tracker, license, topics, SDK ranges, and package descriptions are correct.
- [ ] Generated scan caches and machine-specific Flutter files are absent from commits.
- [ ] Steward applies library rules to libraries and consumer-example rules to examples.
- [ ] Git tags and dependency release order are eLivre, Viewer, then Narration.

### Commands

Run these from the respective repository roots:

```text
# eLivre
dart analyze
dart test
dart test -p chrome test/web
dart pub publish --dry-run

# eLivre Viewer
flutter analyze
flutter test
dart pub publish --dry-run

# Narration
dart analyze
flutter test
dart pub publish --dry-run
```

The release is ready only when the checks pass from clean clones without sibling path overrides.
