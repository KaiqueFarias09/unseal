# Review the code quality of the eLivre v3 libraries

This guide is a manual code review route for eLivre, eLivre Viewer, and eLivre Viewer Narration. It tells you what to read, in what order, and what quality questions to ask.

The automated tests remain responsible for behavior and format correctness. Do not repeat the test suite by manually checking every parsing case. Use tests here only as design evidence: they should exercise public contracts, make module boundaries visible, and permit implementations to change without rewriting unrelated tests.

## How to record the review

Give every review unit one decision:

- **Keep**: the ownership, interface, dependencies, and naming are clear enough for v3.
- **Refactor later**: the design can improve, but the current shape is safe to publish and the debt is precisely recorded.
- **Block v3**: the public contract, ownership, dependency direction, resource lifetime, or failure behavior is unsafe to publish.

For every decision, record the exact files and one short reason. A refactor note must name the concept that should move and the module that should own it. “File is too large” is not enough.

Use these questions throughout the review:

- [ ] Can you state the module's job in one sentence?
- [ ] Does each filename name the concept it owns?
- [ ] Is the public interface smaller than its implementation?
- [ ] Do dependencies point from format adapters toward shared foundations, not between unrelated formats?
- [ ] Are supporting declarations kept with the function or state machine that owns them?
- [ ] Does each abstraction hide a real decision, variation, or platform boundary?
- [ ] Could a reader delete a wrapper without losing a useful boundary? If yes, consider removing it.
- [ ] Are errors translated at the boundary that has enough context to explain them?
- [ ] Are streams, archives, databases, controllers, and platform handles released by a visible owner?
- [ ] Can tests use the same interface that consumers use, with fakes only at deliberate seams?
- [ ] Can a new contributor find the entry point, orchestration, data types, and adapters without searching the whole repository?

Review the repositories in this order:

1. eLivre, which defines the book model and parsing contracts.
2. eLivre Viewer, which consumes those contracts and owns rendering.
3. eLivre Viewer Narration, which depends on both and owns playback.

## Part 1: eLivre

### 1. Public package interface

Read first:

1. `lib/e_livre.dart`
2. `lib/epub.dart`
3. `lib/docx.dart`
4. `lib/odt.dart`
5. `lib/fb2.dart`
6. `lib/html.dart`
7. `lib/txt.dart`
8. `lib/mobi.dart`
9. `lib/azw4.dart`
10. `lib/pdf.dart`
11. `lib/comic.dart`
12. `lib/comic7.dart`

Context: these files are the published surface. Their exports decide what consumers will depend on after v3. Internal folder names can change later; exported names are much more expensive to change.

- [ ] `e_livre.dart` exposes the normal consumer path without exporting format internals by accident.
- [ ] Format entry points expose deliberate expert APIs, not every implementation type.
- [ ] The same concept has one public name across all entry points.
- [ ] Public types do not expose paths under another package's `src/` directory.
- [ ] Deprecated or transitional exports are either removed before v3 or documented with a removal plan.
- [ ] Export barrels do not create cycles or hide duplicate ownership.

### 2. Shared book vocabulary

Read in this order:

1. `lib/src/foundation/entities/book/book.dart`
2. `lib/src/foundation/entities/book/document_book.dart`
3. `lib/src/foundation/entities/book/reading_order_item.dart`
4. `lib/src/foundation/entities/book/files.dart`
5. `lib/src/foundation/entities/file/book_file.dart`
6. `lib/src/foundation/entities/file/binary_file.dart`
7. `lib/src/foundation/entities/file/text_file.dart`
8. `lib/src/foundation/entities/book_metadata.dart`
9. `lib/src/foundation/entities/navigation/navigation.dart`
10. `lib/src/foundation/entities/navigation/nav_point.dart`
11. `lib/src/foundation/entities/book_format.dart`
12. `lib/src/foundation/exceptions/elivre_exception.dart`

Context: `foundation` is the shared language of the package. It should contain concepts used across formats, not leftovers that did not fit elsewhere. A format-specific rule belongs with that format even if several files use it.

- [ ] `Book` is a stable consumer-facing model rather than a union of parser implementation details.
- [ ] `DocumentBook` contains only behavior shared by reflowable document formats.
- [ ] Reading order, navigation, metadata, and files have distinct responsibilities.
- [ ] Foundation types do not import a format feature.
- [ ] Mutable state has a clear owner and is not duplicated across related entities.
- [ ] Equality, identity, nullability, and collection ownership are consistent.
- [ ] Exception types carry useful context without leaking implementation libraries.
- [ ] Barrel files such as `entities.dart` add discoverability without concealing unclear ownership.

Then read the supporting policies:

1. `lib/src/foundation/archive/archive_access.dart`
2. `lib/src/foundation/archive/archive_inventory.dart`
3. `lib/src/foundation/files/book_file_factory.dart`
4. `lib/src/foundation/text/canonical_document_text.dart`
5. `lib/src/foundation/text/document_encoding.dart`
6. `lib/src/foundation/text/plain_text.dart`
7. `lib/src/foundation/text/xml_encoding.dart`
8. `lib/src/foundation/metadata/book_metadata_operations.dart`
9. `lib/src/foundation/metadata/document_metadata.dart`
10. `lib/src/foundation/navigation/html_navigation.dart`
11. `lib/src/foundation/images/cover_helpers.dart`
12. `lib/src/foundation/images/image_dimensions.dart`
13. `lib/src/foundation/images/image_type_sniffer.dart`

- [ ] Each helper is shared by more than one real owner or represents a package-wide policy.
- [ ] Archive access has one lifetime model and does not force every format to understand archive mechanics.
- [ ] Text normalization is separate from format parsing.
- [ ] Metadata merging and precedence rules live in one place.
- [ ] Image sniffing and dimensions do not depend on a particular book format.

### 3. Detection and dispatch

Read in this order:

1. `lib/src/features/detection/entities/detected_format.dart`
2. `lib/src/features/detection/detect_format.dart`
3. `lib/src/features/detection/refine_mobi_format.dart`
4. `lib/src/features/reading/book_dispatch.dart`
5. `lib/src/platform/book_reader.dart`

Context: detection identifies evidence; dispatch chooses an implementation. Keeping them separate prevents file signatures, filenames, parser selection, and I/O from becoming one large conditional module.

- [ ] Detection returns a useful value instead of performing parsing as a side effect.
- [ ] Signature and extension evidence have explicit precedence.
- [ ] MOBI refinement is owned by detection because it refines classification, not by the MOBI parser.
- [ ] Dispatch is the only central map from detected formats to parser entry points.
- [ ] `BookReader` presents a small façade and does not become a second parser implementation.
- [ ] Adding one new format requires a bounded set of changes.

### 4. Simple format adapters

Review simple formats before complex ones. They make the intended adapter shape easiest to see.

#### TXT and TXTZ

Read:

1. `lib/src/features/txt/parse_txt_book.dart`
2. `lib/src/features/txt/text/txt_document.dart`
3. `lib/src/features/txt/archive/txtz_archive.dart`

Context: TXT converts plain text into the common document model; TXTZ adds only archive selection.

- [ ] Parsing orchestration, text interpretation, and archive selection are separate concepts.
- [ ] TXT does not reimplement shared encoding or canonical text rules.
- [ ] TXTZ-specific decisions remain inside the TXT feature.
- [ ] Small private declarations stay beside the function that owns them.

#### HTML and HTMLZ

Read:

1. `lib/src/features/html/parse_html_book.dart`
2. `lib/src/features/html/parsing/html_document.dart`
3. `lib/src/features/html/metadata/html_metadata.dart`
4. `lib/src/features/html/html.dart`

Context: HTML should adapt one document, or an archived HTML publication, to the common model. Shared HTML navigation belongs in foundation only when other formats use the same policy.

- [ ] The parse entry point coordinates instead of owning DOM utilities, metadata policy, and archive policy itself.
- [ ] HTMLZ archive concerns do not leak into ordinary HTML parsing.
- [ ] `html.dart` has a clear purpose distinct from the package entry point.
- [ ] DOM traversal helpers are owned by the operation they support.

### 5. Package-based document adapters

Review DOCX, ODT, and FB2 together because they should express similar layers without being forced into identical implementations.

#### DOCX

Read:

1. `lib/src/features/docx/parse_docx_book.dart`
2. `lib/src/features/docx/container/docx_package.dart`
3. `lib/src/features/docx/container/docx_relationships.dart`
4. `lib/src/features/docx/metadata/docx_metadata.dart`
5. `lib/src/features/docx/styles/docx_styles.dart`
6. `lib/src/features/docx/resources/docx_resources.dart`
7. `lib/src/features/docx/rendering/docx_renderer.dart`
8. `lib/src/features/docx/exceptions/docx_exception.dart`

#### ODT

Read:

1. `lib/src/features/odt/parse_odt_book.dart`
2. `lib/src/features/odt/container/odt_package.dart`
3. `lib/src/features/odt/metadata/odt_metadata.dart`
4. `lib/src/features/odt/styles/odt_styles.dart`
5. `lib/src/features/odt/resources/odt_resources.dart`
6. `lib/src/features/odt/rendering/odt_renderer.dart`
7. `lib/src/features/odt/exceptions/odt_exception.dart`

#### FB2 and FBZ

Read:

1. `lib/src/features/fb2/parse_fb2_book.dart`
2. `lib/src/features/fb2/container/fb2_document.dart`
3. `lib/src/features/fb2/metadata/fb2_metadata.dart`
4. `lib/src/features/fb2/resources/fb2_resources.dart`
5. `lib/src/features/fb2/rendering/fb2_html_renderer.dart`
6. `lib/src/features/fb2/entities/fb2_book.dart`
7. `lib/src/features/fb2/exceptions/fb2_exception.dart`

Context: the parse file should tell the story of each adapter. Container access, relationships, metadata, styles, resources, and rendering deserve separate owners when they carry independent rules. FBZ is a container variation of FB2, not a second document model.

- [ ] Each `parse_*_book.dart` reads as orchestration over named collaborators.
- [ ] Container modules hide path lookup and package layout rules.
- [ ] Metadata modules own extraction and precedence, not rendering.
- [ ] Style conversion is independent from resource discovery.
- [ ] Renderers convert the source model to the common document representation.
- [ ] Similar directory names across formats mean similar responsibilities.
- [ ] Shared code was extracted only where the formats share policy, not merely syntax.
- [ ] Long renderers remain cohesive state machines; split only independent policies or phases.

### 6. EPUB and its owned subfeatures

Read in this order:

1. `lib/src/features/epub/parse_epub_book.dart`
2. `lib/src/features/epub/epub_document.dart`
3. `lib/src/features/epub/container/epub_root_file.dart`
4. `lib/src/features/epub/package/parse_epub_package.dart`
5. `lib/src/features/epub/entities/package/epub_package.dart`
6. `lib/src/features/epub/entities/package/epub_2_package.dart`
7. `lib/src/features/epub/entities/package/epub_3_package.dart`
8. `lib/src/features/epub/content/epub_files.dart`
9. `lib/src/features/epub/metadata/epub_metadata.dart`
10. `lib/src/features/epub/metadata/epub_cover.dart`
11. `lib/src/features/epub/navigation/epub_navigation.dart`
12. `lib/src/features/epub/encryption/epub_encryption.dart`
13. `lib/src/features/epub/codec/epub_xml.dart`
14. `lib/src/features/epub/media_overlays/media_overlay.dart`
15. `lib/src/features/epub/media_overlays/parse_media_overlay.dart`

Context: EPUB is a container format with package metadata, a manifest, a spine, navigation, resources, encryption metadata, and optional media overlays. Media overlays are an EPUB-owned capability because SMIL references the EPUB package and its resources. They are not generic utilities. Playback belongs to the narration package.

- [ ] The top-level parser coordinates root-file discovery, package parsing, content, metadata, navigation, and optional capabilities.
- [ ] EPUB 2 and EPUB 3 variations share a stable package interface without losing version-specific rules.
- [ ] Package entities model the specification rather than parser temporaries.
- [ ] Content lookup and resource ownership are explicit.
- [ ] Encryption handling is isolated from ordinary archive access.
- [ ] Navigation output uses foundation types while EPUB-specific interpretation stays here.
- [ ] Media overlay models describe timing and references without depending on audio playback plugins.
- [ ] `parse_media_overlay.dart` owns SMIL parsing helpers that exist only for that operation.
- [ ] No EPUB implementation code has drifted back into a general `utils` folder.

### 7. Comic containers

#### CBZ and CBR

Read:

1. `lib/src/features/comic/parse_comic_book.dart`
2. `lib/src/features/comic/entities/comic_book.dart`
3. `lib/src/features/comic/metadata/comic_info.dart`
4. `lib/src/features/comic/archive/rar_reader.dart`
5. `lib/src/features/comic/archive/rar4_decoder.dart`
6. `lib/src/features/comic/exceptions/comic_exception.dart`

#### CB7 and CBC

Read:

1. `lib/src/features/comic7/parse_comic7_book.dart`
2. `lib/src/features/comic7/exceptions/comic7_exception.dart`

Context: comic formats adapt ordered images and optional metadata to the book model. CBR requires owned RAR decoding. CB7 and CBC use different containers but should reuse the same comic publication concepts when possible.

- [ ] Page ordering and comic metadata are independent from archive decoding.
- [ ] RAR-specific state machines remain under the comic adapter that owns them.
- [ ] The RAR4 decoder is split by algorithmic responsibility only where that improves comprehension.
- [ ] CB7/CBC reuse common comic concepts without importing CBZ/CBR implementation details.
- [ ] Unsupported container cases fail through format exceptions with actionable context.

### 8. MOBI and AZW4

#### MOBI 6 and AZW3/KF8

Read in layers:

1. `lib/src/features/mobi/parse_mobi_book.dart`
2. `lib/src/features/mobi/reader/mobi_container.dart`
3. `lib/src/features/mobi/header/pdb_header.dart`
4. `lib/src/features/mobi/header/mobi_header.dart`
5. `lib/src/features/mobi/header/exth_header.dart`
6. `lib/src/features/mobi/compression/palmdoc.dart`
7. `lib/src/features/mobi/compression/huff_cdic.dart`
8. `lib/src/features/mobi/index/indx_reader.dart`
9. `lib/src/features/mobi/index/ncx_reader.dart`
10. `lib/src/features/mobi/reader/mobi6_markup.dart`
11. `lib/src/features/mobi/reader/mobi8_structure.dart`
12. `lib/src/features/mobi/reader/mobi8_reader.dart`
13. `lib/src/features/mobi/reader/mobi8_markup.dart`
14. `lib/src/features/mobi/reader/mobi8_resources.dart`
15. `lib/src/features/mobi/metadata/mobi_metadata.dart`
16. `lib/src/features/mobi/entities/mobi_book.dart`

Context: MOBI is several binary layers, not one parser. Header reading, decompression, indexes, markup reconstruction, resources, and metadata are separate decisions. Local helper types may remain with the reader or decoder that owns them.

- [ ] Binary cursor operations are centralized in `codec/mobi_binary.dart`.
- [ ] Header types own structural interpretation, not high-level book construction.
- [ ] Compression algorithms do not know about metadata or rendering.
- [ ] MOBI 6 and KF8 paths share only genuinely common container logic.
- [ ] Index readers expose meaningful results instead of raw offsets everywhere.
- [ ] Resource and markup reconstruction have visible boundaries.
- [ ] Large algorithmic files remain locally coherent and avoid unrelated top-level declarations.

#### AZW4

Read:

1. `lib/src/features/azw4/parse_azw4_book.dart`
2. `lib/src/features/azw4/container/azw4_pdf_extractor.dart`
3. `lib/src/features/azw4/exceptions/azw4_exception.dart`

Context: AZW4 is a Palm-container adapter whose payload is PDF. It may reuse stable MOBI container knowledge and the public PDF parser, but it should not couple their private internals.

- [ ] AZW4 owns payload discovery and extraction.
- [ ] PDF interpretation remains owned by the PDF feature.
- [ ] Reuse crosses through an intentional interface rather than copied binary rules.
- [ ] Errors retain both AZW4 extraction context and the underlying cause.

### 9. PDF

Review PDF last because its complexity can distort standards for smaller modules.

Read in layers:

1. `lib/src/features/pdf/parse_pdf_book.dart`
2. `lib/src/features/pdf/header/pdf_document.dart`
3. `lib/src/features/pdf/header/pdf_object.dart`
4. `lib/src/features/pdf/header/pdf_object_parser.dart`
5. `lib/src/features/pdf/codec/pdf_stream_decoder.dart`
6. `lib/src/features/pdf/security/pdf_security_handler.dart`
7. `lib/src/features/pdf/security/pdf_object_decryptor.dart`
8. `lib/src/features/pdf/reader/pdf_page_tree.dart`
9. `lib/src/features/pdf/reader/pdf_content_stream.dart`
10. `lib/src/features/pdf/reader/pdf_font.dart`
11. `lib/src/features/pdf/reader/pdf_cmap.dart`
12. `lib/src/features/pdf/reader/pdf_outline.dart`
13. `lib/src/features/pdf/reader/pdf_metadata.dart`
14. `lib/src/features/pdf/image/pdf_bitmap.dart`
15. `lib/src/features/pdf/reflow/pdf_reflow.dart`
16. `lib/src/features/pdf/entities/pdf_book.dart`
17. `lib/src/features/pdf/entities/pdf_page.dart`
18. `lib/src/features/pdf/entities/pdf_page_text.dart`
19. `lib/src/features/pdf/codec/ccitt/ccitt_decoder.dart`
20. `lib/src/features/pdf/codec/jbig2/jbig2_decoder.dart`

Context: PDF needs a deep internal design. Syntax, objects, streams, security, page trees, fonts, content instructions, images, text extraction, and reflow should be separable. A deep module can be large when its interface hides that complexity.

- [ ] `parse_pdf_book.dart` is orchestration, not a miscellaneous implementation file.
- [ ] Object parsing is independent from document traversal.
- [ ] Stream filters are selected behind one decoding interface.
- [ ] Security code is isolated and receives only the data it needs.
- [ ] Page-tree traversal, content interpretation, fonts, CMaps, and outlines have distinct owners.
- [ ] Reflow consumes extracted page meaning rather than reaching into parser state.
- [ ] Codec state machines keep tightly coupled tables and state local.
- [ ] Large lookup tables such as `pdf_encodings.dart`, `pdf_standard_widths.dart`, and `ccitt_tables.dart` are treated as data modules, not split to satisfy a line target.
- [ ] Unsupported features fail explicitly instead of silently producing plausible output.

### 10. Format-neutral capabilities

Review these after all format adapters. Their value comes from working across formats.

#### Search

Read:

1. `lib/src/features/search/book_search.dart`
2. `lib/src/features/search/query_compiler.dart`
3. `lib/src/features/search/entities/compiled_query.dart`
4. `lib/src/features/search/entities/search_match.dart`
5. `lib/src/features/search/entities/search_mode.dart`
6. `lib/src/features/search/entities/search_results.dart`

Context: search is a format-neutral capability, not a parser feature. Its current simple layout is a useful baseline: small entry point, explicit compilation, and owned result types.

- [ ] Search depends on the common book/text model, not individual format parsers.
- [ ] Query compilation is separate from traversal and result construction.
- [ ] Result entities describe consumer meaning rather than internal offsets only.
- [ ] The module stays simple unless new search policy actually requires another seam.

#### CFI and locators

Read:

1. `lib/src/features/cfi/epub_cfi.dart`
2. `lib/src/features/cfi/epub_cfi_document.dart`
3. `lib/src/features/cfi/epub_cfi_resolver.dart`
4. `lib/src/features/locators/book_locator.dart`
5. `lib/src/features/locators/locator_codec.dart`
6. `lib/src/features/locators/search_locator.dart`
7. `lib/src/features/locators/fuzzy_relocation.dart`

Context: CFI is an EPUB addressing standard. Locators are the package-wide portable position model. The direction should be CFI into locators, not generic locators depending on EPUB internals.

- [ ] Parsing, document resolution, and public CFI representation are separate.
- [ ] Generic locator types do not import CFI implementation details.
- [ ] Serialization is separated from relocation policy.
- [ ] Fuzzy relocation exposes uncertainty rather than hiding it.

#### Annotations and reading state

Read:

1. `lib/src/features/annotations/bookmark_record.dart`
2. `lib/src/features/annotations/highlight_record.dart`
3. `lib/src/features/annotations/annotation_codec.dart`
4. `lib/src/features/annotations/annotation_merge.dart`
5. `lib/src/features/reading/book_progression.dart`
6. `lib/src/features/reading/nav_resolution.dart`

Context: eLivre owns portable annotation records and position logic. Viewer state and widgets belong to the Viewer package.

- [ ] Portable records contain no Flutter or rendering-engine types.
- [ ] Serialization and merge policy are separate responsibilities.
- [ ] Conflict rules are explicit and deterministic.
- [ ] Reading progression and navigation resolution depend on common book concepts.

#### OPDS and Calibre

Read:

1. `lib/src/features/opds/opds_feed.dart`
2. `lib/src/features/calibre/calibre_database.dart`
3. `lib/src/features/calibre/sqlite_database.dart`
4. `lib/src/features/calibre/entities/calibre_book.dart`

Context: these modules integrate external catalog formats. They should produce clear domain values and keep protocol or database mechanics behind small interfaces.

- [ ] OPDS parsing does not become a networking client unless that is an explicit public feature.
- [ ] Calibre domain values are independent from the selected SQLite implementation.
- [ ] Database ownership and close behavior are visible.
- [ ] External schema quirks are translated at the adapter boundary.

### 11. Platform and worker boundary

Read:

1. `lib/src/platform/worker_book_reader.dart`
2. `lib/src/platform/io/book_path_reader.dart`
3. `lib/src/platform/web/book_path_reader.dart`
4. `lib/src/platform/io/background_parse.dart`
5. `lib/src/platform/io/worker_client.dart`
6. `lib/src/platform/web/background_parse.dart`
7. `lib/src/platform/web/worker_client.dart`
8. `lib/src/platform/web/worker_ops.dart`
9. `lib/src/platform/web/book_wire.dart`
10. `lib/src/platform/web/wire/book_wire_codec.dart`
11. `lib/src/platform/web/wire/error_wire.dart`
12. the remaining files under `lib/src/platform/web/wire/`

Context: platform code adapts files, isolates, and web workers to the same library contract. Wire models are transport representations, not a second domain model.

- [ ] IO and web implementations satisfy the same semantic contract.
- [ ] Conditional imports select adapters without leaking platform types publicly.
- [ ] Worker operations are explicit and versionable.
- [ ] Wire conversion is centralized and does not spread JSON knowledge into domain modules.
- [ ] Domain errors survive transport with useful type and context.
- [ ] Worker and stream lifetimes have a clear owner.

## Part 2: eLivre Viewer

Use absolute paths below because this guide lives in the eLivre repository.

### 12. Public interface and rendering seam

Read:

1. `/Volumes/SSD/Projects/e_livre_viewer/lib/e_livre_viewer.dart`
2. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/rendering/api/viewer_engine.dart`
3. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/rendering/composition/viewer_engine_selector.dart`
4. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/rendering/composition/viewer_engine_selector_io.dart`
5. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/rendering/composition/viewer_engine_selector_web.dart`
6. the adapters under `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/rendering/adapters/`

Context: `ViewerEngine` is the main platform seam. The Viewer should depend on this capability, while platform plugins implement it.

- [ ] The public entry point exports consumer concepts and hides plugin details.
- [ ] `ViewerEngine` is small enough to fake and complete enough to prevent adapter checks elsewhere.
- [ ] Engine selection is composition, not business logic.
- [ ] Each adapter translates plugin events and failures at one boundary.
- [ ] `fake_viewer_engine.dart` validates the seam rather than carrying production behavior.

### 13. Serving pipeline

Read:

1. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_content.dart`
2. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_resource_resolution.dart`
3. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_javascript_policy.dart`
4. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/synthetic_pages.dart`
5. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_html_pipeline.dart`
6. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_server.dart`
7. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_server_io.dart`
8. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/serving/book_server_web.dart`

Context: serving converts an eLivre `Book` into safe content the engine can load. Content lookup, resource resolution, JavaScript policy, HTML transformation, and platform serving are different responsibilities.

- [ ] The HTML pipeline is an ordered composition of named transformations.
- [ ] JavaScript policy is explicit and independently reviewable.
- [ ] Resource resolution has one normalization and security policy.
- [ ] IO and web servers share behavior without sharing platform mechanics.
- [ ] Large pipeline code remains cohesive; extract only a transformation with independent policy.
- [ ] Server disposal is visible from the owning controller or widget lifecycle.

### 14. Navigation state machines

Read:

1. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/navigation/viewer_position.dart`
2. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/navigation/viewer_events.dart`
3. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/navigation/page_estimation.dart`
4. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/controller/page_measurement_controller.dart`
5. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/controller/navigation_coordinator.dart`

Context: these files extract volatile navigation and measurement state from the main controller. This is a strong pattern when each extracted type owns a real state transition or calculation.

- [ ] Value types are immutable and use one coordinate vocabulary.
- [ ] Events describe facts rather than UI commands.
- [ ] Page estimation is independent from widget state.
- [ ] The measurement controller owns measurement lifecycle and cancellation.
- [ ] The navigation coordinator owns ordering, races, and pending requests.
- [ ] Neither controller reaches into a concrete engine adapter.

### 15. Viewer façade

Read:

1. `/Volumes/SSD/Projects/e_livre_viewer/lib/src/controller/viewer_controller.dart`
2. `/Volumes/SSD/Projects/e_livre_viewer/test/viewer_controller_test.dart`
3. `/Volumes/SSD/Projects/e_livre_viewer/test/navigation_coordinator_test.dart`

Context: `ViewerController` is expected to be broad because it coordinates consumer operations. It becomes a problem only when it reimplements serving, navigation, annotations, search, or engine adapters instead of delegating to them.

- [ ] The public façade has a coherent lifecycle.
- [ ] State mutations flow through a small number of named operations.
- [ ] Extracted collaborators own their state instead of mirroring controller fields.
- [ ] Concurrency, cancellation, and stale callbacks are handled deliberately.
- [ ] Tests observe public behavior and use `ViewerEngine` as the substitution seam.

### 16. Viewer capabilities and presentation

Review in this order:

1. bridge: `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/bridge/viewer_bridge.dart`
2. annotations: `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/annotations/`
3. search: `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/search/viewer_search.dart`
4. PDF modes: `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/pdf/` and `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/pdfjs/`
5. MathJax: `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/mathjax/`
6. settings: `/Volumes/SSD/Projects/e_livre_viewer/lib/src/features/settings/`
7. widgets: `/Volumes/SSD/Projects/e_livre_viewer/lib/src/widgets/`

Context: Viewer features adapt library concepts to an interactive reading session. Portable data stays in eLivre; live state, engine commands, and Flutter presentation stay here.

- [ ] The bridge validates messages and translates them into typed events.
- [ ] Annotation query, mutation, merge adaptation, and export have separate owners.
- [ ] Export formats share an intermediate document or rendering policy where useful.
- [ ] Viewer search adapts eLivre results instead of duplicating search semantics.
- [ ] PDF.js and MathJax loaders isolate platform loading and failure handling.
- [ ] Settings are value objects rather than a bag of unrelated widget state.
- [ ] Widgets compose controllers and values without owning parsing or serving policy.
- [ ] Folder structure reflects durable capabilities, not individual screens only.

## Part 3: eLivre Viewer Narration

### 17. Public interface and playback contracts

Read:

1. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/e_livre_viewer_narration.dart`
2. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/narration_state.dart`
3. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/narration_controller.dart`
4. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/speech_engine.dart`
5. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/clip_player.dart`
6. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/sources/narration_runner.dart`

Context: narration owns playback policy. `SpeechEngine`, `ClipPlayer`, and `NarrationRunner` are substitution seams for platform plugins and source strategies.

- [ ] The public entry point exposes the façade and useful values, not plugin implementations by default.
- [ ] Narration state represents consumer meaning and has valid transitions.
- [ ] Controller and runner responsibilities are distinct.
- [ ] Speech and clip interfaces model capabilities rather than mirroring third-party plugins.
- [ ] Cancellation, completion, error, pause, resume, and disposal semantics are unambiguous.
- [ ] Interfaces are easy to fake without reproducing internal state.

### 18. Source strategies

Read:

1. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/sources/tts/tts_chapter_plan.dart`
2. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/sources/tts/tts_narration_runner.dart`
3. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/sources/media_overlay/media_overlay_catalog.dart`
4. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/sources/media_overlay/media_overlay_narration_runner.dart`

Context: TTS and EPUB media overlays are two implementations of narration. eLivre parses overlay structure; this package resolves it into playback and coordinates audio.

- [ ] Chapter planning is separate from speech-engine execution.
- [ ] The TTS runner depends on `SpeechEngine`, not a concrete Flutter plugin.
- [ ] The media-overlay catalog resolves publication references without reparsing EPUB internals.
- [ ] The overlay runner depends on `ClipPlayer`, not a concrete audio package.
- [ ] Both strategies report state through the same runner contract.
- [ ] Source-specific helpers live with their owning strategy, not in a generic `utils` folder.

### 19. Façade, adapters, media session, and presentation

Read:

1. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/viewer_narration.dart`
2. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/adapters/flutter_tts_speech_engine.dart`
3. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/playback/adapters/just_audio_clip_player.dart`
4. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/media_session/narration_audio_handler.dart`
5. `/Volumes/SSD/Projects/e_livre_viewer_narration/lib/src/presentation/narration_bar.dart`
6. `/Volumes/SSD/Projects/e_livre_viewer_narration/test/viewer_narration_test.dart`

Context: `ViewerNarration` coordinates Viewer position and narration sources. Adapters translate plugins. The media session translates operating-system controls. The bar is presentation only.

- [ ] `ViewerNarration` delegates source execution and does not absorb adapter mechanics.
- [ ] Viewer synchronization crosses a narrow public Viewer interface.
- [ ] Plugin adapters contain all plugin-specific conversions and quirks.
- [ ] Media-session callbacks invoke narration operations without duplicating playback state.
- [ ] `NarrationBar` renders state and sends intent without owning playback policy.
- [ ] Every subscription, callback, player, and engine has one disposal owner.
- [ ] Tests substitute at the declared interfaces rather than patching internals.

## Part 4: Cross-package consistency

### 20. Ownership map

Use this ownership rule when a concept could fit in more than one repository:

| Concept | Owner |
| --- | --- |
| Book formats, parsing, metadata, resources, portable positions | eLivre |
| EPUB media-overlay structure and SMIL interpretation | eLivre EPUB feature |
| Rendering, serving, interactive navigation, viewer state | eLivre Viewer |
| Speech, audio clips, playback policy, OS media controls | eLivre Viewer Narration |
| Third-party or platform implementation | An adapter inside the package that owns the capability |

- [ ] Every cross-package dependency follows this direction.
- [ ] No package imports another package's `src/` files.
- [ ] Shared types have one owner rather than copies in multiple packages.
- [ ] A lower package does not depend on a higher package to gain convenience behavior.
- [ ] Optional integrations stay outside the base eLivre package when they require Flutter or platform plugins.

### 21. Directory consistency

Apply these names by responsibility, not by quota:

- `entities/`: stable domain values with little orchestration.
- `container/`: physical package, archive, or binary-container access.
- `metadata/`: extraction and metadata policy.
- `resources/`: discovery and mapping of embedded resources.
- `rendering/`: conversion into a displayable representation.
- `codec/`: encoding, decoding, or transport conversion.
- `adapters/`: implementation of a deliberate interface using an external system.
- `composition/`: implementation selection and dependency assembly.
- `exceptions/`: errors owned by the module.

- [ ] The same folder word means the same kind of responsibility across formats.
- [ ] A one-file concept is not wrapped in folders without improving navigation.
- [ ] `utils`, `helpers`, `common`, and `misc` are absent unless the name is genuinely the clearest owner.
- [ ] Feature directories contain the code required for the feature, including private supporting declarations.
- [ ] Foundation contains shared policy, not merely reused syntax.

### 22. Files with many declarations or many lines

Do not use a line limit as an architecture rule. Review large files using this sequence:

1. State the file's single responsibility.
2. Group its declarations by the decision or state they support.
3. Trace which declarations change together.
4. Identify any independent concept with its own invariant or lifecycle.
5. Extract only when the new file gains a clear name and reduces the context required to understand both sides.

- [ ] Private parser records used by one parser remain with that parser.
- [ ] Closely coupled decoder state remains with its algorithm.
- [ ] Large static tables remain dedicated data modules.
- [ ] Independent public entities live in their own clearly named files.
- [ ] Independent adapters, policies, state machines, and lifecycle owners are separated.
- [ ] Extraction does not create a chain of thin files that must be opened together.
- [ ] A proposed split improves locality, testing, replacement, or comprehension.

### 23. Tests as architecture evidence

Do not manually replay implementation cases already covered by tests. Inspect representative tests only to answer these design questions:

- `test/public_format_entrypoints_test.dart` and `test/public_search_api_test.dart`: can consumers use only supported entry points?
- format parser tests: can the parser be exercised through its owned entry point?
- worker and wire tests: is the platform boundary stable and serializable?
- `/Volumes/SSD/Projects/e_livre_viewer/test/viewer_controller_test.dart`: can the façade be tested through the rendering seam?
- `/Volumes/SSD/Projects/e_livre_viewer/test/format_viewer_integration_test.dart`: do library and Viewer meet through public contracts?
- `/Volumes/SSD/Projects/e_livre_viewer_narration/test/public_entry_point_contract_test.dart`: is narration's public surface deliberate?
- `/Volumes/SSD/Projects/e_livre_viewer_narration/test/viewer_narration_test.dart`: can source and plugin behavior be substituted at owned interfaces?

- [ ] Tests fail when a public contract changes, not whenever a private file moves.
- [ ] Most tests do not import `lib/src/` across package boundaries.
- [ ] Fakes implement real interfaces rather than duplicate production orchestration.
- [ ] Complex algorithms have focused tests close to their responsibility.
- [ ] Integration tests cover seams between packages without making internal layouts permanent.

### 24. Final v3 code-quality decision

Finish with one short table:

| Review unit | Decision | Files | Reason or follow-up |
| --- | --- | --- | --- |
| Public APIs | Keep / Refactor later / Block v3 |  |  |
| Foundation |  |  |  |
| Detection and dispatch |  |  |  |
| TXT and HTML |  |  |  |
| DOCX, ODT, and FB2 |  |  |  |
| EPUB |  |  |  |
| Comics |  |  |  |
| MOBI and AZW4 |  |  |  |
| PDF |  |  |  |
| Format-neutral capabilities |  |  |  |
| Platform and workers |  |  |  |
| Viewer |  |  |  |
| Narration |  |  |  |
| Cross-package boundaries |  |  |  |

The manual review is complete when every row has a decision, every **Block v3** item is resolved, and every **Refactor later** item names a concrete owner and reason. The automated suite remains the source of truth for implementation behavior.
