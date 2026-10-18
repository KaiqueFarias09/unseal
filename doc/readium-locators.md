# Readium Locators and position lists

This document fixes the normative contract for Unseal's Readium Locator
interchange and deterministic position-list generation before the
implementation. The implementation, tests, and versioned comparators in
`tool/readium/` cite this file. Nothing here claims to be a Readium
publication except the pinned official artifacts named below.

## Oracles and their authority

| Artifact | Role | Authority |
| --- | --- | --- |
| `@readium/shared` 2.8.0 (BSD-3-Clause) | Executed reference for `Locator.deserialize`/`serialize` | Official toolkit. Its observed behavior over the fixed corpus is the interchange oracle. |
| Official Locator JSON Schema, pinned at `readium/architecture` `schema/locator.schema.json` | Syntax validation | Official schema. The pinned raw file carries one trailing comma outside strings (source SHA-256 `4a35a3e4…`); its bytes are preserved and validation uses only the syntax-derived file (`3e573b81…`, derivation recorded in `locator-derivation.json`). The raw file never validates anything. |
| Readium positions document (`models/locators/positions/README.md`, pinned `4b99dcf4…`) | Normative contract for the position-list service shape | Official document. |
| `tool/readium/positions_verify.py` | Independent verifier for position lists | **Local tool.** The official position-list schema path returned 404 at preparation time; no official schema exists for the service shape and none is claimed. This verifier is a project contract, never presented as official. |
| Locator spec README (pinned `f98efc35…`) | Normative field tables and examples | Official document. |

Round-tripping Unseal's own payloads is never an interchange oracle: only the
executed toolkit, the pinned official schema, and the independent verifier
count.

## Interchange corpus

`tool/readium/corpus/locator-cases.json` fixes the interchange corpus. Cases
`spec-example-1..3` and `position-list-spec-example` carry the official
examples verbatim; `toolkit-smoke` carries the preparation's exercised input.
Cases `legacy-fragment`, `href-fragment-split`, `out-of-range-locations`,
`unknown-extensions`, `missing-href`, `missing-type`, and `text-partial` are
declared synthetic edge cases. Expected outputs are never stored in the
corpus — the reference runner derives them by executing the toolkit, and the
comparator refuses to run when the reference artifact is missing, records a
failed reference command as a failure, and reports a mutated field as a
mismatch.

## Observed toolkit semantics (normative for interchange)

Behavior below is what the executed toolkit 2.8.0 did over the corpus; the
Dart model reproduces it.

| Input | Toolkit behavior | Unseal contract |
| --- | --- | --- |
| `href` or `type` missing/empty | Refuses the locator | Same: typed rejection for string input, `null` for map input |
| `href` carrying `#fragment` | Splits: keeps the resource part in `href`, moves the fragment into `locations.fragments` when no fragments are present | Same on import (tolerant), flagged as a normative violation of "href must not point to a fragment"; never produced on export |
| `locations.fragment` (singular, legacy — the spelling the official positions example uses) | Accepted; folded into `fragments` when `fragments` is absent or empty | Same on import (tolerant); export always emits `fragments` as an array |
| `progression`/`totalProgression` outside `[0,1]`, `position` `< 1` | Values dropped; locator stays valid; schema-invalid input is accepted by the toolkit (recorded divergence) | Same: drop-and-keep, and the outcome records that the input was schema-invalid |
| Unknown keys inside `locations` | Kept as opaque `otherLocations`; re-emitted top-level inside `locations` on serialize | Same, bounded by the extension policy below |
| `text` object | Only non-absent fields serialize (`after`, `before`, `highlight` order) | Same |
| Numbers | JS serialization: `0.0` emits as `0` | Dart emits `0.0`; comparison is numeric (exact IEEE double equality), never byte equality of serialized JSON |

Serialization key order (`href`, `type`, `title`, `locations`, `text`) is
observed but not contractual; comparisons are structural.

## Extension policy

Unregistered keys inside `locations` (extension points per the spec, e.g. the
registered HTML extension or URI-named keys) are preserved opaquely with
these bounds, and gain no local meaning: they never influence conversion,
resolution, or position generation. Bounds: at most 16 extension keys per
locations object, each key at most 256 characters, each value at most 4096
bytes when serialized (nested depth at most 8). Payloads exceeding the bounds
fail typed instead of being truncated.

## Conversion model

Conversions between `ReadiumLocator` and Unseal's `BookLocator` produce
exactly one outcome:

- **Exact** — every field of the target is derivable without guessing: EPUB
  CFI locators resolve through the existing `EpubCfiResolver` to a reading
  order section and offsets, and the locator's resource equals the resolved
  section; PDF `page=N` fragments map one-to-one onto native zero-based page
  indexes; comic hrefs match a page path.
- **Approximate** — a usable but lossy target: a text locator with no CFI
  confirmation, an href that matched a resource whose occurrence context is
  only partial, or a locator whose locations carry no resolvable expression
  but whose resource is known. The outcome carries what was recovered.
- **Ambiguous** — the evidence matches more than one target: a repeated
  resource in the reading order without occurrence context, or multiple
  equally-ranked matches. No candidate is chosen; the candidates are
  reported, bounded.
- **Unsupported** — the locator cannot address this book: foreign href, CFI
  that does not resolve, out-of-range page, or a media type the book does not
  carry. Nothing is guessed.

**Reuse requires context.** A locator alone never certifies it still
addresses a book. Verified reuse requires a `ReadiumLocatorContext` carrying
the publication revision (identity, revision, evidence), the reading-order
occurrence (index, exact path, reading-order revision digest), and the text
profile. A revision, profile, or occurrence mismatch reports
`incompatible`/`ambiguous` instead of resolving. Structurally valid JSON
permits inspection without asserting it addresses any book.

**Resource addressing.** Resource hrefs carry no fragment. EPUB and comic
hrefs are the parser's exact resource paths — the same strings
`session.loadResource` resolves; Unseal invents no URI. PDF locators use the
host-confirmed document URI (a required argument the host supplies; Unseal
never mints one) with `page=N` fragments, where `N` is the one-based fragment
page and Unseal's native page index is zero-based; the conversion is
`fragment = nativeIndex + 1`, `nativeIndex = fragment - 1`, and a fragment of
`page=0` or a value past the page count is unsupported.

**UTF-16.** All public character offsets (text locator bounds, CFI offsets,
quote evidence) stay UTF-16 code units, matching the existing canonical-text
contract. Only anchor *spacing* below is measured in Unicode scalar values.

## Position-list profile `unseal.readium.positions/1`

The versioned generation profile. Positions are generated per reading-order
**occurrence** — a resource repeated in the reading order emits its own
positions for each occurrence; repeated hrefs never collapse.

- **Reflowable sections** (HTML reading-order items with non-empty canonical
  text): anchor scalar offsets are `{0} ∪ {1024k : k ≥ 1, 1024k ≤ lastAnchor}`
  where `lastAnchor` is the largest multiple of 1024 strictly below the
  section's scalar length — the first position of each occurrence is the
  scalar-0 anchor, which is why it is named in the profile. Each anchor maps
  to its UTF-16 offset (the offset of the first code unit of the scalar at
  that scalar index; an anchor at a high surrogate maps to the surrogate's
  own offset and the pair is never split). The density 1024 is Unseal's
  declared choice: it is not a Readium requirement and does not claim to
  match another producer's position list.
- **Empty sections**: exactly one position at offset 0 with local progression
  `0.0`; the global progression equals the share of text before the section.
- **PDF and comics**: exactly one position per page. Comics address each page
  image resource by its path; PDF positions carry the host document URI with
  fragment `page=N+1` for zero-based page `N` (one position per page, no
  text locations). Page positions carry local `progression = 0.0` — the
  position sits at the resource start of an atomic page resource — and
  `totalProgression = i / N` for the zero-based page `i` of `N` pages, the
  share of positions before it over the page total. A mixed book computes
  `totalProgression` per space: text sections share the text total, pages
  share the page count, and the two spaces are never mixed into one
  denominator (documented consequence: a mixed book's `totalProgression` is
  not a single monotonic book fraction; consumers filter by occurrence).
- **Mixed corpora**: reflowable items get the anchor rule, image/page items
  get the page rule, in reading-order sequence. A DjVu/other book with no
  HTML text and no page model yields an empty list — an empty list is a
  valid outcome, never an error.
- **Non-linear items**: EPUB spine items with `linear="no"` are auxiliary
  content. The profile keeps them: Readium position lists describe the
  publication's resources, and skipping them would make `position` indexes
  disagree with the manifest. Their presence is recorded in generation
  coverage, and consumers can filter by occurrence using the reported paths.
  This is a declared Unseal decision, not a Readium norm.
- **Formulas.** With UTF-16 section lengths `L_i`, section start offsets
  `S_i = Σ_{j<i} L_j`, total `T = Σ L_i`, and anchor UTF-16 offset `o` inside
  section `i`: local `progression = o / L_i` (`0.0` when `L_i = 0`), global
  `totalProgression = (S_i + o) / T` (`0.0` when `T = 0`). Both are IEEE-754
  double divisions of UTF-16 lengths — the same space `BookProgression`
  measures, so session and eager progressions agree. `position` is the
  one-based index in the emitted list, and `total` equals the list length.
  Empty books (no positions) serialize as `{"total": 0, "positions": []}`.
- **Determinism.** Generation is a pure walk of the reading order under the
  profile: no clocks, no randomness, no map-iteration order. The same book
  bytes and identity produce byte-identical JSON.
- **Parity.** Eager and session generation over the same book produce
  identical lists when the canonical-text profile matches (the
  `document-text` profile). PDF lists bind their reading mode's reflow
  profile: a list generated under one mode never claims validity under the
  other.
- **Cost.** Generating a full list can materialize the entire book text.
  Session generation walks one occurrence per step through the existing
  session APIs, reports coverage after each step, accepts cancellation
  between steps, and enforces limits; it never claims progressivity.

Service JSON follows the pinned positions document: `{"total": N,
"positions": [Locator…]}`; the manifest link constants are media type
`application/vnd.readium.position-list+json` and relation
`http://readium.org/position-list` (declared for hosts; Unseal does not
fetch or serve lists). Position entries carry `href`, `type`,
`locations.position`, `locations.progression`, `locations.totalProgression`
— the profile emits no fragments, a declared choice; consumers needing
resource-entry anchors get them from the locator conversion APIs.

## Limits and failures

All limits precede allocation:

| Limit | Value | Failure |
| --- | --- | --- |
| Locator JSON input bytes | 1 MiB | `ReadiumLocatorLimitException` |
| Locator JSON nesting depth | 32 | `ReadiumLocatorLimitException` |
| `fragments` count / fragment length | 64 / 4096 chars | `ReadiumLocatorLimitException` |
| Extension keys / key length / value bytes / value depth | 16 / 256 / 4096 / 8 | `ReadiumLocatorLimitException` |
| Text context field length | 64 KiB chars | `ReadiumLocatorLimitException` |
| Position list entries | 100 000 | `ReadiumPositionLimitException` |
| Ambiguous candidate reports | 8 | bounded, reported |

Malformed structure (missing `href`/`type`, wrong value types, bad numbers)
fails typed as `ReadiumLocatorFormatException` from string-parsing entry
points; the map-level decode reports rejection by returning `null` for
forward-compatibility, mirroring the toolkit's `undefined`. Hostile payloads
never leak `FormatException`/`TypeError`/`RangeError`.

## Coverage and cancellation (session generation)

`ReadiumPositionListBuilder` over `BookSession` walks occurrences one by one,
reports `ReadiumPositionCoverage` (occurrences completed / total, positions
emitted) after each step, and honors a `ReadiumPositionCancellationToken`
between steps: a cancelled build returns the frozen partial list plus
coverage, leaving the session usable. Disposal fails pending work with the
session's typed `SessionClosedException`. Two concurrent sessions build
independently.

## Verification corrections

PDF imports through both Book and BookSession require `documentUri`, supplied
by the host, equal to the locator href. A CFI must resolve into the same
reading-order occurrence selected by href and occurrenceHint. Contradictory
CFI/resource evidence is unsupported. The string codec applies the caller's
semantic limits as well as its JSON preflight limits.

Position generation caps cumulative canonical UTF-16 text per pass at
`ReadiumPositionLimits.maxTextCodeUnits` (64 Mi units by default), including
repeated reading-order occurrences. Anchor storage is checked against the
remaining position budget during the scalar walk. Coverage callbacks describe
the positions already emitted for the completed occurrence. Session text
loading continues to use the session's own decode and cache limits.

Oracle dependencies are installed locally with `npm ci --prefix tool/readium
--ignore-scripts --no-audit --no-fund`; only the lockfile and drivers are tracked.
