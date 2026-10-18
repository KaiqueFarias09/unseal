# OPDS 2.0 JSON catalogs

Unseal parses OPDS 2.0 catalog documents into a format-neutral model. A
catalog is reading data, not a book file: the host performs every network
operation — fetching feeds, following links, authenticating, purchasing,
borrowing, and decryption all stay in the application. Parsing never
fetches anything, and no fetch API exists in the OPDS surface.

The existing OPDS 1.x Atom parser (`OpdsFeed`, `OpdsEntry`, `OpdsLink`,
`OpdsAuthor`) is unchanged. The JSON model lives beside it with `Opds2`
prefixed types; both are exported from `package:unseal/unseal.dart` and
from the narrow `package:unseal/opds.dart` entry point.

## Public API

| Entry | Purpose |
| --- | --- |
| `parseOpds2Feed` / `parseOpds2FeedBytes` | Parse a feed document (`application/opds+json`). |
| `parseOpds2Publication` / `parseOpds2PublicationBytes` | Parse a standalone publication document (`application/opds-publication+json`). |
| `Opds2Feed`, `Opds2Group`, `Opds2Facet`, `Opds2Publication`, `Opds2Link`, `Opds2Metadata`, `Opds2FeedMetadata`, `Opds2Contributor`, `Opds2Subject`, `Opds2Subcollection` | The mapped model. |
| `Opds2LinkProperties`, `Opds2Price`, `Opds2AcquisitionObject`, `Opds2Holds`, `Opds2Copies`, `Opds2Availability`, `Opds2Encryption` | Acquisition and link property data. |
| `resolveOpds2Href` | Resolve a link target against an explicitly supplied base URL. |
| `expandOpds2Template` | Expand the supported URI-template subset. |
| `isOpds2AcquisitionRel`, `opds2AcquisitionRels` | Acquisition relation vocabulary. |
| `Opds2Limits` | Resource bounds (see below). |
| `Opds2MalformedException`, `Opds2LimitExceededException` | Typed failures. |

Mapped feed members: `metadata` (title, identifier, `@type`, subtitle,
modified, description, `numberOfItems`, `itemsPerPage`, `currentPage`),
`links`, `navigation`, `publications`, `groups` (nested, with their own
metadata/links/navigation/publications), `facets`, and every unknown member
as a named `Opds2Subcollection` (the feed schema's extension point).
Publication metadata maps the Readium subset: identifiers (including
`altIdentifier`), language maps for title/sortAs/subtitle, the fourteen
contributor roles, subjects, languages, published, modified, description,
duration, `numberOfPages`, layout, `readingProgression`, and the
`accessibility` object (preserved as data, not modeled).
Links map `href`, `rel` as string or list (`rels`), `templated`, `type`,
`title`, `language`, `height`, `width`, `size`, `bitrate`, `duration`,
`alternate`, `children`, and the OPDS/EPUB/encryption `properties`
(`numberOfItems`, `price`, `indirectAcquisition`, `holds`, `copies`,
`availability`, `contains`, `layout`, `encrypted`, `page`).

## Absent, invalid, and extension values

- **Absent** optional members map to null or stay empty. Required members
  (`metadata.title`, `links`, link `href`, group `metadata`, acquisition
  object `type`) reject when missing.
- **Invalid** values — a wrong type, an unparseable `modified` timestamp,
  an invalid calendar date, a non-finite numeric value, or
  a publication without an acquisition relation — throw
  `Opds2MalformedException` carrying a JSON pointer to the offending
  value.
- **Extensions** follow one documented policy: members outside the mapped
  subset are dropped. Feed-level unknown members are the exception the
  schema itself defines — they map as subcollections, and a member that is
  not a valid subcollection rejects. Unseal adds no speculative aliases,
  raw-JSON back doors, or canonicalization for unknown data; a host that
  needs an unmapped member reads the JSON it already holds.

## Rules the schema does not enforce

The official JSON Schemas (Draft 7, pinned by SHA-256, see below) are one
reference; the normative text of the OPDS 2.0 specification is another.
The parser applies both, and where they disagree the parsing rule is:

| Rule | Schema | Normative text | Parser |
| --- | --- | --- | --- |
| Feed has `metadata.title` | required | must | rejects |
| Feed has a `self` link | enforced via `contains` | must | rejects |
| Feed has at least one of navigation/publications/groups | `anyOf` | must | rejects |
| Navigation links carry a title | enforced via `allOf` | must | rejects |
| Facet has a title in its metadata | **not enforced** (facet `metadata` optional) | must | rejects |
| Search links are templates with `{?query}` | **not enforced** | "always expressed using a URI template with at least one query parameter" | rejects |
| Publication has an acquisition link | enforced via `contains` | must | rejects |
| Images include one jpeg/avif/webp/jxl/png/gif | enforced via `contains` | must | rejects |
| `modified` is RFC 3339 date-time | `format` is an annotation | must | validates calendar date, time and offset; leap-second `:60` values are outside the supported subset and reject typed |
| Price object carries `value` | **not enforced** | price "provides the decimal value" | rejects missing value |
| Currency is a current ISO 4217 code | enum of codes | — | checks three-letter shape only (documented subset) |
| Language tags are BCP 47 | full pattern | must | lightweight subtag shape check (documented subset) |
| Metadata has no blank values | — | should not | accepted (recommendation, not a rule) |
| Standalone publication has a `self` link | not required | should | accepted without (recommendation) |

Two canonical spec examples themselves violate the official schema: the
publications feed uses only `rel: download` on its single publication, and
the pagination fragment carries no collection role. Both fail the schema
reference and the parser identically; the corpus pins them as negative
cases so the divergence stays visible.

## URI resolution and templates

`href` values are stored verbatim. Resolution happens only when the host
passes a base explicitly to `resolveOpds2Href`:

- Absolute references and references with their own scheme resolve to
  themselves, so `opds://` or `mailto:` targets stay data and nothing
  invents a fetchable URL for an unknown scheme.
- Relative references go through RFC 3986 resolution (`Uri.resolve`),
  covering paths, empty references, query-only, fragment-only, percent
  escapes, and Unicode references without rewriting the stored data.
- Without a base, the href is returned parsed and unchanged.

`expandOpds2Template` supports the subset OPDS 2.0 actually uses — literal
text, `{var}`, and `{?var}` (form-style query). Other RFC 6570 expression
forms are copied through unchanged. Search links must carry a `query`
parameter (see the rules table); expansion is convenience, not required
for parsing.

## Limits

`Opds2Limits` bounds are checked before the corresponding allocation:

| Bound | Default | Checked |
| --- | --- | --- |
| `maxBytes` | 16 MiB | before UTF-8/JSON decoding |
| `maxDepth` | 64 | preflight walk before mapping |
| `maxNodes` | 250,000 JSON values | preflight walk before mapping |
| `maxStringLength` | 1 MiB | preflight walk before mapping |
| `maxPublications` | 5,000 (feed level and per group) | while mapping |
| `maxGroups` | 1,000 | while mapping |
| `maxFacets` | 1,000 | while mapping |
| `maxSubcollections` | 1,000 (feed level and nested) | while mapping |
| `maxLinks` | 10,000 per container | while mapping |

Crossing a bound throws `Opds2LimitExceededException` before the model
allocation that the input would cause. Defaults suit catalog-sized
documents; larger feeds require an explicit `Opds2Limits` copy.

## Reference execution and corpus

The pinned reference is jsonschema 4.25.1 + referencing 0.37.0 on
CPython 3.12.14, running the official OPDS 2.0 feed/publication schemas
plus the full Readium Web Publication closure — 26 schema documents
fetched from specs.opds.io and readium.org, pinned by SHA-256 in
`test/resources/opds/corpus-manifest.json` and copied with verified
hashes into `build/` before execution. The registry loads every schema
locally; validation never touches the network. One load-time translation
applies: the BCP 47 patterns use JS named-group syntax, which the Python
`re` engine requires as `(?P<name>...)` — pattern semantics are
unchanged.

The corpus (all pinned by SHA-256, provenance in
`test/resources/opds/PROVENANCE.md`):

- **Real independent catalogs** — the three OPDS 2.0 feeds of the
  Feedbooks test catalog (`Feedbooks/opds-test-catalog` gh-pages,
  commit `d04db71d6151578db3101af5b28711b41d977300`, published for OPDS
  client testing), byte-identical.
- **Canonical spec examples** — eight documents extracted from the OPDS
  2.0 specification (feeds for navigation, groups, nested featured
  groups, pagination; search-template link fragments), including the two
  that the official schema rejects (see above).
- **Declared synthetic fixtures** — Unicode/escape/query/fragment mixes,
  facets, nested groups, subcollections, `rel` lists, price and library
  properties; plus minimal negative and normative-only rejections.

`tool/opds2_schema_oracle.py` validates every case against the pinned
closure and pins per-feed expectations in
`test/resources/opds/expected/` (generated from the raw JSON by Python,
never by the Dart code). The Dart corpus test compares `parseOpds2Feed`
summaries against those pinned expectations and `resolveOpds2Href`
against `urljoin` expectations. The shared-cases generator embeds the
same bytes and expectations for the Chrome suite, so VM and browser run
identical cases; a VM test re-checks the embedded copy against the
on-disk files.

One reference divergence surfaced while building the corpus: a
dot-segment case with a percent-encoded segment exposed an old
`urljoin` deviation in the pinned Python 3.12 when the expected value was
hand-written. The generator now computes every manual expectation through
`urljoin` itself, and `Uri.resolve` matches it on RFC 3986 behavior.

## Out of scope

Authentication Documents, Open Distribution to Libraries (ODL) flows,
effective purchase/borrow transactions, DRM/LCP handling, network
fetching, and catalog persistence stay with the host. The parser reads
`borrow`/`buy`/`subscribe` relations and their properties as data. An
Authentication Document fed to the parser fails typed like any other
non-feed document.

## Testing

- VM: `dart test test/tests/opds/` — model, corpus cross-check, typed
  failures, limits, URI resolution, state isolation, and the OPDS 1.x
  Atom regression suite.
- Chrome: `dart test -p chrome test/web/opds2_web_test.dart` — the same
  embedded corpus and resolution expectations. OPDS parsing does not use
  the worker wire; both platforms call the same pure library code.
- Benchmarks: `dart run tool/opds2_bench.dart` records parse time and
  RSS by feed size; `tool/opds2_acceptance_sweep.dart` additionally
  measures per-size peak RSS with `/usr/bin/time -l` over a fresh AOT
  binary.
