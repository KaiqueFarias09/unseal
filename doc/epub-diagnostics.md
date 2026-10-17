# EPUB structural diagnostics

Unseal can report EPUB structural and reference diagnostics while reading
stays untouched. `diagnoseEpub` and `diagnoseEpubArchive` (exported from
`package:unseal/epub.dart`) return an `EpubDiagnosticsReport` with stable,
deterministic findings. Diagnostics never repair a book, never fetch
external resources, and never change what `Unseal.read`, `parseEpubBook`, or
any session API accepts or rejects.

## Contract

Every finding is an `EpubDiagnostic` with:

- `ruleId`: a stable identifier from the catalog below. IDs follow
  `epub.<area>.<condition>` and never change meaning between releases.
- `severity`: `error` or `warning`.
- `resource`: the archive-relative path of the affected resource, when known.
- `location`: a rule-specific pointer such as `manifest item "ghost"` or
  `spine[2]`, when known.
- `reason`: a deterministic human-readable explanation.

The report carries the resolved `rootFilePath`, the declared package
`version` when the OPF parsed, the `findings` in a deterministic order
(container, package, manifest, spine, navigation, guide; document order
inside each stage), a `truncated` flag, and severity counts. The subset is
explicitly narrower than EPUB conformance: a report with no findings is not
an EPUB conformance claim.

## Rule catalog and EPUBCheck mapping

The oracle is EPUBCheck 5.4.0 from the official distribution
(`epubcheck-5.4.0.zip`, SHA-256
`33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c`), run on
OpenJDK. Mappings below were measured by running EPUBCheck over the
committed fixtures in `test/resources/epub/diagnostics/`, not taken from
documentation. EPUBCheck reports one condition through several message IDs
in some cases; the comparator treats all messages mapped to a rule as
confirmation that the condition exists in the oracle run.

| Rule ID | Severity | Condition | EPUBCheck 5.4.0 messages (severity) |
| --- | --- | --- | --- |
| `epub.container.mimetype-invalid` | error | `mimetype` entry absent, not the first entry, or carrying a different string. | PKG-006 (ERROR), PKG-007 (ERROR) |
| `epub.container.missing` | error | `META-INF/container.xml` is absent. | RSC-002 (FATAL) |
| `epub.container.rootfile.missing` | error | Container has no `rootfile` element, or none names a package usable as OPF. | RSC-003 (ERROR) |
| `epub.container.rootfile.path-unresolved` | error | `rootfile/@full-path` names an entry that is not in the container. | OPF-002 (FATAL) |
| `epub.container.rootfile.media-type-unsupported` | error | Every `rootfile` declares a media-type other than `application/oebps-package+xml`. | RSC-003 (ERROR) |
| `epub.package.version-unsupported` | error | `package/@version` missing or unsupported. | OPF-001 (ERROR) |
| `epub.manifest.item.incomplete` | error | Manifest `item` missing required `href`, `id`, or `media-type`. | RSC-005 (ERROR, "missing required attribute") |
| `epub.manifest.resource-missing` | error | Manifest item href resolves to no archive entry. | RSC-001 (ERROR) |
| `epub.manifest.id-duplicate` | error | Two manifest items share `id`. | RSC-005 (ERROR, `Duplicate "…"`), RSC-008 (ERROR) |
| `epub.manifest.href-duplicate` | error | Two manifest items resolve to the same path. | OPF-074 (ERROR) |
| `epub.manifest.href-fragment` | error | Manifest item href carries a fragment. | OPF-091 (ERROR) |
| `epub.manifest.remote-resource-undeclared` | error | Manifest href is an absolute URL without the EPUB 3 `remote-resources` property (EPUB 2 has no declaration mechanism, so it always reports). | RSC-006 (ERROR) |
| `epub.spine.reference-invalid` | error | Spine `itemref/@idref` matches no manifest item. | OPF-049 (ERROR), RSC-005 (ERROR) |
| `epub.spine.empty` | error | Spine has no `itemref`. | RSC-005 (ERROR, `spine incomplete`) |
| `epub.spine.reference-duplicate` | error | Two spine items reference the same manifest entry. | RSC-005 (ERROR, "same manifest entry as a previous itemref") |
| `epub.navigation.nav-missing` | error | EPUB 3 package declares no manifest item with `properties="nav"`. | RSC-005 (ERROR, `number of "nav" items: 0`) |
| `epub.navigation.nav-duplicate` | error | More than one EPUB 3 nav item. | RSC-005 (ERROR, `number of "nav" items: 2`) |
| `epub.navigation.toc-missing` | error | EPUB 3 nav document has no `toc` nav section; or EPUB 2 NCX missing/unresolvable through `spine/@toc`. | RSC-005 (ERROR, `Exactly one "toc" nav element`), RSC-001 (ERROR, toc.ncx not found) |
| `epub.navigation.toc-reference-missing` | error | EPUB 2 spine lacks the `toc` attribute. | RSC-005 (ERROR, `spine missing required attribute "toc"`) |
| `epub.navigation.link-unresolved` | error | Navigation link (EPUB 3 nav anchor or NCX `content/@src`) resolves to no archive entry. | RSC-007 (ERROR) |
| `epub.navigation.fragment-unresolved` | error | Navigation link fragment does not match any `id` in the target document. | RSC-012 (ERROR) |
| `epub.guide.reference-unresolved` | error | EPUB 2 guide reference target is absent from the archive or not declared in the manifest. | OPF-031 (ERROR), RSC-007 (ERROR) |

Severity policy: conditions that EPUBCheck reports as ERROR or FATAL inside
this subset map to Unseal `error`. Warnings stay reserved for conditions the
oracle treats as advisory; the advisory interop warning EPUBCheck emits for
file names containing spaces (PKG-010) is outside the subset and is not
reported.

## Out of scope, explicitly

The subset is structural: container, package, manifest, spine, navigation,
guide. Everything EPUBCheck checks beyond it is out of scope and never
appears in Unseal findings, including: XHTML/HTML content-document validity
(most RSC-005 messages), CSS, metadata value formats, accessibility,
media overlays, page lists' target semantics, encryption.xml, signatures,
or font obfuscation. Unseal diagnostics being silent about those does not
make a book conformant, and the report type does not carry a conformance
verdict.

## Reading behavior and typed failures

Diagnostics do not change any existing outcome:

- Books the reading path accepts today are accepted unchanged, even when
  they carry findings (a missing `container.xml` is recovered by scanning
  `.opf` entries today; the diagnostic still reports it).
- Books the reading path rejects with a typed failure are rejected
  unchanged. `epub.manifest.item.incomplete` is an example: diagnosis
  reports the condition, `parseEpubBook` still throws `EpubException`.
- Safety boundaries stay typed failures: ZIP corruption, expansion,
  encryption, or unsupported-compression failures are thrown by
  `decodeBookZip` before diagnosis runs and are never downgraded to
  findings. A malformed OPF XML document (not well-formed) also fails
  typed instead of producing findings.

## Limits

Diagnostics run under the same container safety limits as reading
(`decodeBookZip`), plus report-specific bounds in `EpubDiagnosticsOptions`:

- `maxFindings` (default 400): collection stops and `truncated` becomes
  true; findings already collected stay ordered and stable.
- `maxNavigationLinks` (default 2000): navigation and guide link
  resolution stops early with `truncated`.
- `maxFragmentResourceBytes` (default 1 MiB): fragment checks skip target
  documents above the cap, with `truncated`.
- `maxManifestItems` (default 20000): items beyond the cap are not
  diagnosed individually.

All limits are applied before untrusted data is expanded further, and
crossing a report bound is visible through `truncated` rather than silent.
Safety-limit violations keep the existing typed exceptions.

## Reference comparison

`tool/compare_epub_diagnostics_oracle.dart` drives the reproducible oracle:
it verifies the distribution digest, runs EPUBCheck over read-only copies
of every fixture, and compares reports under the policy in
`doc/epub-diagnostics.md`. Synthetic fixtures are deterministic and carry
their expected rules in `test/resources/epub/diagnostics/manifest.json`;
real licensed books complement the corpus, and their expected findings are
derived from the oracle output through the mapping table above. Oracle
exit code 1 with a parsed report is an expected rejection of an invalid
book; a missing report or a tool crash is a tool failure and fails the
comparison.
