# hOCR import (D02)

Unseal imports hOCR sidecars as a reading feature, the same way it imports
ALTO and PAGE XML: the host supplies the document and the canonical text it
confirmed, Unseal parses the declared subset and binds positioned words onto
the UTF-16 ranges of that text. Unseal does not run OCR, does not render, and
does not own persistence. This document fixes the subset, the title grammar,
every policy the parser applies, the comparison contract, and the limits. It
was written before the comparison lane ran; the lane proves the parser
follows it, not the other way round.

## Subset and sources

The normative text is hOCR 1.2 (`https://kba.github.io/hocr-spec/1.2/`,
Markdown source SHA-256
`48b7e5f325629d7d0a2219a475d8ae68a2e0463d68c328cbe09ddd51e5986093`) and its
machine-readable element and property table `1.2/defs.yml` (SHA-256
`78b7ef805e310dd227973c047e7085514bf07e7a6751003dba697e99bb7b272d`). hOCR is
HTML with a class vocabulary, so the input is HTML or XHTML bytes; Unseal
parses both through its HTML parser after the preflight described below.

The subset is the reading hierarchy: pages, content areas, paragraphs,
lines and words, plus the document metadata that names the producer. The
spec's logical elements (`ocr_chapter`, `ocr_section`, ...), floats
(`ocr_photo`, `ocr_separator`, `ocr_table`, ...), inline elements
(`ocr_glyph`, `ocr_cinfo`, `ocr_dropcap`, ...) and the grouping mechanism
are outside the subset. Unseal does not claim coverage of the whole format.

## Element classification

An hOCR element is any HTML element whose `class` attribute, split on ASCII
whitespace, contains a token starting with `ocr_` or `ocrx_`. The HTML tag
does not matter and the hOCR token does not have to be the only class. The
spec text says "exactly one class name" starting with the prefix; Unseal
reads that as a producer rule and classifies by token, so Tesseract's `<p
class='ocr_par'>` and a hypothetical `<span class="word ocrx_word">` both
import.

| Token | Role | Why |
| --- | --- | --- |
| `ocr_page` | page | Required by the spec in every hOCR document. |
| `ocr_carea`, `ocrx_block`, `ocr_column` | block | `ocr_carea` is the content area; `ocrx_block` is the engine-specific block the spec defines for commercial engines; `ocr_column` is the deprecated name of `ocr_carea` and is accepted with its token recorded. |
| `ocr_par` | paragraph | The logical paragraph; Tesseract nests it inside `ocr_carea`, ABBYY FineReader 11 hangs it straight off the page. |
| `ocr_line`, `ocrx_line` | line | The typesetting line and its engine-specific variant. |
| `ocr_header`, `ocr_caption`, `ocr_textfloat` | line when the element has no line descendant; transparent container otherwise | Tesseract 4 and 5 emit the paragraph's block type as the class of the line element in place of `ocr_line` (`hocrrenderer.cpp`: `PT_HEADING_TEXT`, `PT_CAPTION_TEXT`, `PT_PULLOUT_TEXT`). Those elements carry `id='line_N_M'`, `baseline`, `x_size` and direct `ocrx_word` children. The spec lists them as floats with a required `bbox`; a producer that uses them as blocks containing `ocr_line` elements gets the transparent-container treatment. The declared token stays on the line. |
| `ocrx_word` | word | The engine word; the only word element the spec defines. |
| any other `ocr_*`/`ocrx_*` token | transparent container | Its descendants are walked and its text contributes to the enclosing word or line; its own properties are not modeled. This covers Tesseract's empty `ocr_photo` and `ocr_separator` blocks, logical sectioning, floats, inline elements, and `ocr_cinfo`. |

An element with two or more role tokens (for example `ocr_line ocrx_word`)
is refused: the classification is ambiguous and Unseal does not pick one.
A role token beside non-role hOCR tokens classifies by the role token.

Nesting is the document's own. A page may contain blocks, paragraphs, lines
and words in whatever combination the producer declared, so `page > line`
(ocropy, kraken), `page > paragraph > line > word` (ABBYY) and `page >
block > paragraph > line > word` (Tesseract) all import with exactly the
ancestors that are present. Shapes that invert the hierarchy fail typed: a
page inside any element, a block inside a paragraph, line or word, a
paragraph inside a line or word, a line inside a line or word, a word inside
a word, and a word outside any line (every word needs the line whose zone
it nests in; no producer in the corpus writes loose words).
Elements outside any `ocr_page` are ignored; a document without an
`ocr_page` is not an hOCR document and fails typed.

## Title grammar

Every hOCR element's `title` attribute holds the properties. The grammar is
the spec's ABNF with the deviations the corpus forced, each named here:

- Properties are separated by `;` with optional ASCII whitespace on either
  side (`bbox 698 83 726 147 ;` from gcv2hocr has a trailing space).
- A `,` also separates properties when it is directly followed by optional
  whitespace, a token that satisfies the property-name grammar, and at least
  one space. kraken 0.8.0 writes `bbox 86 61 152 101, x_confs 0.91 0.96`.
  The spec's own `cuts 9 11 7,8,-2 15 3` and kraken's `cuts 0,0,20,0
  27,0,41,0` keep their commas because what follows each comma is a digit,
  and a property name starts with a letter. Under the strict ABNF the
  kraken title is one `bbox` property with eight value tokens, which the
  arity check below would refuse; the comma rule is the declared
  producer-compatibility extension.
- A property name is `[a-z][a-z0-9_]*`. Names outside the spec's list and
  without the `x_` prefix (ocropy's `file`) are accepted as data, not
  refused: the spec's name rule is a producer rule, the files exist, and
  refusing them would discard whole producers. Names with uppercase letters,
  a leading digit or other characters fail typed.
- Values are whitespace-separated tokens; a token may be a double-quoted
  string that itself may contain spaces or semicolons (`image
  "/foo/bar.png"`); the quotes are removed from the token. An unterminated
  quote fails typed. The ABNF requires quotes for `image`, `lpageno`,
  `cflow`, `x_font`, `x_scanner` and `x_source`; a bare token is accepted
  for the string properties the subset consumes (kraken writes `image
  tests/resources/bw.png`). Empty segments (a trailing `;`) are ignored.
- The same property name twice on one element fails typed. The spec has no
  rule for duplicates and Unseal does not choose a winner.
- A `title` longer than the title budget, or more properties than the
  per-element budget, fails typed before the DOM exists (preflight) and
  again while parsing.

### Consumed properties

| Property | Elements | Grammar applied | Model |
| --- | --- | --- | --- |
| `bbox` | all roles | exactly four non-negative integers `x0 y0 x1 y1`, `x1 >= x0`, `y1 >= y0` | `HocrBox` in image pixels, top-left origin; `width = x1 - x0`, `height = y1 - y0`. Zero extent is accepted as declared (gcv2hocr writes `bbox 0 0 0 0` on its page); an inverted box fails typed; a non-integer or negative token fails typed. |
| `baseline` | lines | two or more finite numbers, at most eight | `HocrBaseline.coefficients` verbatim in stored order (`pn ... p0`), `order = count - 1`. The spec's ABNF says `float int`; Tesseract 5.5.3 writes `baseline 0.029 -12.192`, so both coefficients are read as decimals. The polynomial lives in the line's frame with the bottom-left corner of the line's `bbox` as origin and y growing downward. |
| `x_wconf` | words (data on any other role) | one token | `HocrConfidence`: a token that starts with a digit, `-` or `.` must satisfy the decimal grammar and lie in `0..100`, or it fails typed (`1e400`, `101`, `-1`); `declared` is that 0..100 value and `shared` is `declared / 100` for the spatial contract. Any other token (`unknown`, `inf`) is a declared non-numeric confidence kept as `declaredToken` with no value. A missing property has no record at all. Absent, unknown and zero are three different states; none of them becomes another. |
| `textangle` | all roles | one finite decimal | degrees, counter-clockwise, native. It never rotates coordinates or the spatial page; the spatial projection's rotation is always 0. |
| `scan_res` | page | two non-negative integers; one integer is accepted as both axes | `scanResolutionX`/`Y` in DPI. |
| `ppageno` | page | one non-negative integer | `physicalPageNumber`. Recorded, never used to reorder pages. |
| `lpageno` | page | one token, quoted or bare | `logicalPageNumber` verbatim. |
| `image` | page | zero or one token, quoted or bare | `imageName`; ABBYY writes `image ;` and the empty value imports as null. |
| `imagemd5` | page | one token, quoted or bare | `imageMd5` verbatim; no hex check, the digest is provenance data. |
| `hardbreak` | lines | `0` or `1` | `hasHardBreak`. |
| `order`, `cflow` | any | present | `HocrUnsupportedFeatureException`. Document order is the reading order; an element that declares a different order or a content flow asks for a reconstruction Unseal does not perform. |

Every other property, spec-defined or not (`x_size`, `x_descenders`,
`x_ascenders`, `x_font`, `x_fsize`, `x_bboxes`, `x_confs`, `cuts`, `nlp`,
`poly`, `x_source`, `x_scanner`, `file`, ...), is recorded verbatim as
`properties[name] = tokens` on the element. Their arity and syntax are not
checked beyond the lexical grammar. `poly` does not replace `bbox`: an
element whose role requires a box and that declares only `poly` fails the
required-property rule.

Required properties follow `defs.yml`: `bbox` on pages, blocks and lines.
A page without `bbox` is accepted (see the frame rule below) because the
ocropy and OCRopus producers omit it; a block or line without `bbox` fails
typed; paragraphs and words are not required to carry one. A word without a
box binds its text but emits no zone; a paragraph without a box is never the
region of its lines (the nearest boxed ancestor is).

## Text

The text of a word or line is the concatenation of its descendant character
data in document order after HTML entity decoding, with these rules:

- inline markup (`strong`, `em`, `b`, `i`, `span`, `sup`, `sub`, ...)
  contributes its text and nothing else; Tesseract 3.04 writes
  `<strong>` and `<em>` inside `ocrx_word`;
- `del` and everything under it contributes nothing; `ins` contributes its
  text; the presence of either marks the element as carrying alternative
  readings (the spec's `span.alternatives` with `ins`/`del` children);
- `br` contributes nothing;
- whitespace is preserved exactly as decoded; nothing is trimmed,
  collapsed or normalized. Tesseract separates `ocrx_word` siblings with
  whitespace that belongs to no word; ocropy's `<span class='ocr_line'>t
  W-</span>` keeps its inner space;
- no Unicode normalization is applied; text travels as the producer wrote
  it;
- offsets are UTF-16 code units everywhere. Astral characters occupy two
  code units; byte offsets and code-point counts are never used.

`lang`, `xml:lang` and `dir` travel verbatim on every modeled element when
declared; no vocabulary is enforced. `id` travels verbatim and may be
absent (ocropy lines have none) or repeated; nothing in the subset
addresses elements by id and Unseal makes no uniqueness claim.

## Metadata

`<meta name="ocr-system" content="...">`, `ocr-capabilities`,
`ocr-number-of-pages`, `ocr-langs` and `ocr-scripts` are read from `head`.
The spec requires exactly one `ocr-system` and one `ocr-capabilities`;
kraken 0.8.0 omits `ocr-capabilities` and OCRopus 2007 writes `ocr-id` with
a `value` attribute instead. A missing field is null, a field declared
twice fails typed. `ocr-capabilities`, `ocr-langs` and `ocr-scripts` split
on whitespace; `ocr-number-of-pages` parses as an integer when it is one.
The declared page count is not compared with the parsed page count and
capabilities are not checked against the elements present; both travel as
data. `ocr-system` is the spatial provenance's `softwareName` verbatim;
`softwareVersion` is null because producers do not separate the two
consistently (`ABBYY FineReader Engine 11`, `tesseract 5.5.3`, `gcv2hocr`).

## Geometry

Boxes are integer pixels in the image's top-left space; `SpatialRect`
carries `x0, y0, x1 - x0, y1 - y0` exactly. No unit or scale step exists.

The baseline stays native. `HocrBaseline.evaluate(dx)` returns the
polynomial's value for a horizontal offset from the line's left edge, in
the line's bottom-left frame (negative values sit above the bottom edge).
`HocrLine.baselineYAt(x)` is the named projection into page space:
`bbox.y1 + evaluate(x - bbox.x0)`. Nothing else projects or rotates.

`textangle` stays native on the element; `SpatialTextPage.rotation` is 0
for every hOCR page because the property describes rotated content inside
the page, not the page's orientation.

The page frame is the geometry the spatial page is built on, chosen in this
order and recorded as `HocrPage.frameSource`:

1. `declared`: the page's `bbox` when it has positive width and height;
2. `derivedFromContent`: the union of every boxed descendant's `bbox`
   when the page has no `bbox` or a zero-extent one (ocropy, OCRopus,
   gcv2hocr). The union is a named derivation of declared boxes, not a
   guess; the spatial page's width and height are the union's `x1` and
   `y1`, so every zone fits the frame the way it fits the image;
3. `none`: no boxed descendant either. The page parses, binds its text,
   and emits no spatial page.

In both projected cases the spatial page's width and height are the
frame's `x1` and `y1`: hOCR coordinates are absolute in the image, so a
frame that does not start at the origin still needs a page that reaches
its far edges.

## Binding to a host-confirmed snapshot

`bindHocrToSnapshot` binds a parsed document onto one
`CanonicalTextSnapshot` the host supplies. Nothing in the file proves which
publication, section and profile received the OCR; the host confirms that
and the result carries the target's identity tuple (publication revision,
occurrence, profile, text revision) so a persisted binding verifies reuse
against exactly the text it addresses.

Units bind at the finest granularity each line declares: words with
bindable content map individually; a line whose words carry none, or that
has no words, maps its own text. The bindable content of a unit is its
model text with leading and trailing ASCII whitespace (space, tab, LF, CR,
FF) removed; a unit that is empty after that binds nothing and counts as
nothing. The model text itself stays verbatim. The rule exists because
Tesseract 3.04/3.05 and gcv2hocr serialize indentation inside
`ocrx_word` (`<span class='ocrx_word'>\n   <em>P</em>\n  </span>`) and
Tesseract 3.04 emits whitespace-only words; non-ASCII spaces such as
U+00A0 are content and stay. A reading cursor walks the target text
across all pages in document order: the first occurrence at or after the
cursor resolves, one fallback to the document start happens when nothing
follows the cursor, absence is reported as missing. More than one
occurrence in the whole text makes the unit ambiguous with its bounded
candidate list, and so does an alternative reading on the unit or on any
ancestor. Repeated quotes, alternative readings and a scan the candidate
budget truncated never certify uniqueness. Astral characters and
diacritics compare as exact UTF-16 code units. Every search, including
candidate collection, charges the projection budget before it scans and
fails typed when the budget would be exceeded.

The spatial projection follows DjVu's rule for levels a file skips. Zones
are emitted per page in depth-first order:

- the region zone is the nearest boxed ancestor of the line among
  paragraph, block and page, emitted once while consecutive lines share
  it (Tesseract: the paragraph; ABBYY: the paragraph; ocropy and kraken:
  the page frame);
- the line zone is the line's own box over the aggregate of its mapped
  units;
- the word zone is the word's own box when it has one.

Zone confidence is the word's `shared` confidence; line and region zones
carry none because the format declares none there.
`SpatialTextProvenance.hasConfidence` is true when any word declared
`x_wconf` with a value.

## Limits

Checked before the DOM is built (a linear scan over the decoded text that
counts tags, nesting, attributes and the `title`/`class` lengths) and again
while walking the tree, all failing typed with `HocrException`:

| Limit | Value |
| --- | --- |
| Input bytes | 32 MiB |
| Tag nesting depth | 128 |
| Elements per document | 1,048,576 |
| Elements per page | 65,536 |
| Attributes per element | 64 |
| `title` attribute length | 4,096 characters |
| `class` attribute length | 1,024 characters |
| Properties per element | 64 |
| Value tokens per property | 256 |
| Pages per document | 4,096 |
| Blocks per page | 16,384 |
| Paragraphs per block or page | 16,384 |
| Lines per container | 16,384 |
| Words per line | 4,096 |
| Words per document | 1,048,576 |
| Text per word or line | 4,096 UTF-16 code units |
| Baseline coefficients | 8 |
| Binding candidate occurrences per unit | 16 (configurable, >= 2) |
| Binding projection work | 64 Mi code-unit scans (configurable) |

Non-finite numbers cannot be written in the grammar, but `1e400`,
`Infinity`, `NaN` and friends are refused typed wherever a number is
consumed. `x_wconf` is the one place a token that does not start like a
number is data rather than a refusal (see the property table).

## Corpus and reference

The reference is executed, not asserted. `tool/hocr_reference.py` runs
Tesseract 5.5.3 (Leptonica 1.87.0, `eng.traineddata` SHA-256
`7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2`) with
`-c tessedit_create_hocr=1 -c tessedit_create_tsv=1` so hOCR and TSV come
from the same recognition pass, then extracts records from every corpus
file with lxml 6.1.1 (an HTML parser, not a schema: hOCR has no XSD and
none is implied). `tool/hocr_compare.dart` parses the same files with the
Dart parser and diffs the records field by field; it also diffs the
Tesseract hOCR against its own TSV under the normalization below.

Images (Apache-2.0, `tesseract-ocr/test`, `testing/`): `phototest.tif`
(640x480, 200 dpi), `eurotext.tif` (1024x800, 300 dpi, German and French
words with diacritics and guillemets), `8071_093.3B.tif` (3312x2550,
300 dpi, nine content areas, captions, a pull-out, photo and separator
blocks) and `8087_054.3B.tif` (2560x3300, 300 dpi, headers, captions,
photo blocks). `multipage.tif` is the `tiffcp` concatenation of
`phototest.tif` and `eurotext.tif` and yields one hOCR with two
`ocr_page` elements from one execution. Image hashes, command lines, exit
codes and output hashes are in the reference report.

External sidecars (CC0-1.0, `kba/ocr-fileformat-samples`, `samples/hocr/`)
and what each one exercises:

| File | Producer | Shape |
| --- | --- | --- |
| `060.hocr` | Tesseract 3.04.01 | seven content areas, `strong`/`em` inside words, `lang` and `dir` on words |
| `417576986_0012.hocr` | ABBYY FineReader Engine 11 | `page > par > line > word`, no block, no `x_wconf`, no `baseline`, `image ;` |
| `417576986_0013.hocr` | tesseract 3.05.00dev | `xml:lang` beside `lang`, `em` inside words |
| `433934212_0017.html` | ocropy 0.4 | `page > line` with plain text, no `bbox` on the page, unknown `file` property, lines without `id` |
| `alice.hocr` | OCRopus revision 312 (hOCR 2007) | no doctype, `ocr-id` meta with `value`, `page > par > line` plain text, no `bbox` on the page |
| `jp_vert.hocr` | gcv2hocr (Google Cloud Vision) | 700 single-word lines each in its own area and paragraph, CJK text, `bbox 0 0 0 0` on the page, trailing space before `;` |
| `kraken_bw_example.hocr` | kraken 0.8.0 | HTML5 doctype, comma-separated properties, `cuts` on lines, `x_confs` on words, no `ocr-capabilities`, `br` between lines |
| `wetzel_reisebegleiter_1901_0021.hocr` | tesseract 3.03 | Fraktur print, `xml:lang`, full hierarchy |

Derived documents committed under `test/resources/hocr/` are marked
`derived` in `PROVENANCE.md`: they add what no real producer in the corpus
writes (astral characters, `ins`/`del` alternatives, `textangle`, `dir`
on lines, `hardbreak`, `ocrx_block`, `ocr_column`, mixed class lists) and
the refusal documents (`order`, `cflow`, inverted boxes, duplicate
properties, nesting inversions, budget overflows).

### TSV normalization

Tesseract's TSV has one row per page (level 1), block (2), paragraph (3),
line (4) and word (5) with `left top width height conf text`. The hOCR
and the TSV come from the same iterator, and the join is by document order
per page after this normalization, fixed from the preparation smoke and
the reference run:

- a level-5 row whose `text` is empty or whitespace-only is a non-text
  block placeholder (image and separator blocks; 32 such rows on
  `8071_093.3B`) and takes part in no join; every other level-5 row is a
  word and matches the k-th `ocrx_word` of the same page;
- a level-4, -3 or -2 row owning at least one such word matches the k-th
  line, paragraph or block of the same page that owns at least one
  word; lines include the Tesseract line-role classes;
- `bbox` matches `(left, top, left + width, top + height)` exactly;
- hOCR `x_wconf` is the TSV `conf` truncated toward zero (`37.676090`
  writes as `37`, `33.577732` as `33`); equality is exact after
  truncation;
- `text` matches exactly after entity decoding, with no normalization;
- the level-1 row count equals the `ocr_page` count and its
  `width`/`height` equals the page `bbox` extent.

Lossless means zero differences in every unit above. A difference is a
finding to analyze, never a tolerance to widen after the fact.

## Worker transport

`hocr.bind` mirrors `pageXml.bind`: the worker parses the sidecar bytes and
binds them against a resident DjVu page's hidden-text snapshot under a
host-supplied identity; the reply is the structured-clone-safe wire view of
the binding and the typed failures cross the error wire with their own
types. The public functions run unchanged inline.

## Out of scope

OCR execution, hOCR export or editing, the logical, float and inline
element families beyond the transparency rule above, `poly` geometry,
`cuts`/`x_bboxes`/`x_confs` semantics, grouped elements, `order`/`cflow`
reading-order reconstruction, rendering and persistence. D02 does not
depend on any other campaign D mission.
