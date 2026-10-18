# PAGE XML import (C02)

Unseal imports PAGE OCR sidecars as a reading feature, the same way it
imports ALTO: the host supplies the document and its target text, Unseal
parses the declared subset and binds positioned words onto the canonical
UTF-16 text the host confirmed. Unseal does not run OCR, does not render,
and does not own persistence.

## Subset and version

The supported namespace is exactly
`http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15`,
validated against the official schema of that date (SHA-256
`5d7da5af5f5e06d3b9cd1e78b407ffca1862f78ad9823ed89c302fb6409932d5`).
Any other namespace — including other PAGE releases such as 2013 or
2019-03 — fails with `PageXmlUnsupportedFeatureException`. Unseal does
not claim coverage of the whole PAGE format.

Parsed content:

- `Metadata` (Creator, Created, LastChange, Comments);
- `Page` identity: imageFilename, imageWidth/imageHeight, resolution
  figures, page-level orientation and confidence, languages;
- `Border` and `PrintSpace` polygons;
- all fifteen region kinds, with `TextRegion` parsed deep (lines,
  words, geometry, language, reading direction, line order, orientation);
- `Coords` polygons and `Baseline` point lists, native, integer;
- `ReadingOrder` with nested ordered/unordered groups and indexed
  region refs;
- `TextEquiv` with alternatives: `Unicode`, optional `PlainText`,
  declared `index` and `conf` (0–1).

Ignored as data (declared policy): `AlternativeImage`, `Layers`,
`Relations`, `TextStyle`/typography attributes, `UserDefined`,
`Labels`, `Roles`, glyph/grapheme trees, `CustomAttribute` payloads
and the `custom` attribute's embedded conventions. They travel nowhere;
a host that needs them reads the source bytes. Descriptive enumeration
tokens (`type`, `readingDirection`, `textLineOrder`, `production`,
`align`, resolution units) travel verbatim as declared data; their
vocabulary is the XSD lane's job, and an out-of-vocabulary token is a
declared acceptance, not a parse failure. Elements the subset
requires but cannot serve — malformed points, confidence outside 0–1,
a `TextEquiv` without `Unicode`, a ReadingOrder reference to an
undeclared region, duplicate or cyclic group structure — fail typed
with `PageXmlException` or, when the failure is one of scope, with
`PageXmlUnsupportedFeatureException`.

## Geometry: native polygons, projected boxes

PAGE polygons stay native: integer point lists in the image's pixel
space (the schema fixes top-left origin; there is no unit ambiguity
and no scale step). `PageXmlPolygon` carries the stored points. The
bounding box is explicitly derived — `PageXmlGeometry.boundingBox`
computes it from the polygon and the shared `SpatialTextZone.rect`
that the foundation contract carries is that projection, never a
second copy of the source geometry. Nothing discards the polygon.

Orientation is preserved natively (page-level and per-region floats).
PAGE orientation is a display-space correction hint; coordinates stay
in page space. The shared projection keeps the page's rotation only
when the declared page orientation is an exact multiple of 90
degrees; fractional skew stays on the native model and the host
applies its own display transform. Binding never rotates text ranges.

## Reading order

When the page declares a valid `ReadingOrder`, text regions emit in
reading-order index sequence; nested groups recurse depth-first.
Region refs must resolve, group indexes must be unique among
siblings, and a group may not contain itself or its ancestor — every
violation fails typed instead of guessing. Without a ReadingOrder the
stored region order is the reading order.

## TextEquiv choice

A node's alternatives are ordered by declared `index`; the chosen
text is the first alternative with the lowest index, document order
breaking ties. That rule is deterministic and applies identically at
region, line and word level. The chosen `Unicode` content is what
binds; alternatives and confidences stay queryable on the model.

## Binding to a host-confirmed snapshot

`bindPageToSnapshot` binds the parsed document onto one
`CanonicalTextSnapshot` the host supplies — schema validity alone
never proves identity, the host confirms which publication, section
and profile received the OCR. The result carries the target's
identity tuple (publication revision, occurrence, profile, text
revision) so persisted bindings verify reuse against exactly the text
they address; a changed origin or revision no longer matches.

Words bind at the finest granularity the document declares:

- words with chosen `Unicode` map individually;
- a line whose words carry no text maps its own chosen text;
- a region without text-bearing lines maps its own chosen text.

The scan walks the target text with a reading cursor: the first
occurrence at or after the cursor resolves; more than one occurrence
in the whole text is real ambiguity with a bounded candidate list;
absence is observable as missing. Repeated quotes, alternate
readings and truncated scans can never certify uniqueness. Limits
bound candidate collection and total projection work before hostile
data is traversed; exceeding them fails typed.

## Limits

Checked before allocation, all failing typed:

| Limit | Value |
| --- | --- |
| Input bytes | 32 MiB |
| XML nesting depth | 128 |
| XML elements per document | 1,048,576 |
| XML elements per page | 65,536 |
| Regions per page | 16,384 |
| Lines per region | 16,384 |
| Words per line | 4,096 |
| Points per polygon | 4,096 |
| TextEquiv alternatives per node | 32 |
| Unicode content per node | 4,096 characters |
| ReadingOrder entries per page | 16,384 |
| Group nesting | 8 |
| Binding candidate occurrences per word | 16 (configurable, ≥ 2) |
| Binding projection work | 64 Mi code-unit scans (configurable) |

## Corpus and reference

The reference is executed, not asserted. Real sidecars come from the
OCR-D `gt_structure_text` corpus (CC-BY-SA-4.0, four works printed
1506–1897, German and Latin, including Fraktur long-s and combining
marks), each with its target image. Every file validates against the
pinned official XSD with lxml/libxml2, and an independent lxml
extractor (`build/c02/reference/extract_page_xml.py` in the mission
workspace) produces the field/geometry/text records the Dart parser
is diffed against. Synthetic documents are identified as derived and
complement — never replace — the licensed corpus. Schema validity
does not certify reference integrity: libxml2 does not resolve
`xs:IDREF`, so reference validation stays the parser's job and the
dangling-reference document is a declared schema-valid parser
negative.

## Worker transport

`pageXml.bind` mirrors `spatial.alto.bind`: the worker binds the
sidecar against a resident DjVu page's hidden-text snapshot under a
host-supplied identity, and the reply is a structured-clone-safe wire
view of the binding. The public functions run unchanged inline.

## Out of scope

OCR execution, other PAGE versions, PAGE export/editing, hOCR,
rendering, and persistence. C02 does not depend on tiled TIFF work.
