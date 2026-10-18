import 'dart:math' as math;

import '../../foundation/spatial/spatial_text_page.dart';
import '../../foundation/spatial/spatial_text_zone.dart';
import '../../foundation/spatial/spatial_unit.dart';
import '../../foundation/spatial/spatial_zone_lookup.dart';
import '../../foundation/text/canonical_text_snapshot.dart';
import '../../foundation/text/publication_revision.dart';
import '../../foundation/text/section_occurrence.dart';
import '../../foundation/text/text_profile.dart';
import 'page_document.dart';
import 'page_exception.dart';

/// Work bounds of one PAGE-to-snapshot binding. The projection scan is
/// linear in the target text per searched unit; the budget keeps a
/// hostile document from quadratic work and reports the refusal typed.
final class PageXmlBindLimits {
  /// Creates the limits.
  const PageXmlBindLimits({
    this.maxCandidateOccurrences = 16,
    this.maxProjectionWork = 64 * 1024 * 1024,
  });

  /// Validates the declared limits; [ArgumentError] reports values the
  /// binding cannot serve. Public entry points call this before
  /// relying on the values.
  void requireValid() {
    if (maxCandidateOccurrences < 2) {
      throw ArgumentError.value(
        maxCandidateOccurrences,
        'maxCandidateOccurrences',
        'Must be at least two to detect ambiguity',
      );
    }
    if (maxProjectionWork < 1) {
      throw ArgumentError.value(maxProjectionWork, 'maxProjectionWork', 'Must be positive');
    }
  }

  /// How many occurrences (at least two) of one unit's content the
  /// mapping records as ambiguity candidates before it stops counting.
  final int maxCandidateOccurrences;

  /// The total characters one binding may scan across all its
  /// searches.
  final int maxProjectionWork;
}

/// Where a mapped unit sits in the parsed document. Line and word
/// indexes are null for line- and region-level mappings — the
/// granularity levels the sidecar itself declares.
final class PageXmlWordPlace {
  /// Creates the place.
  const PageXmlWordPlace({required this.regionIndex, this.lineIndex, this.wordIndex});

  /// The region's index in the page's stored region order.
  final int regionIndex;

  /// The line's index inside its region, when the unit is a word or a
  /// line.
  final int? lineIndex;

  /// The word's index inside its line, when the unit is a word.
  final int? wordIndex;
}

/// One ambiguous mapped unit: its place in the imported document and
/// the bounded candidate ranges the target text offers. Distinct OCR
/// readings can make a unit ambiguous even with one target candidate.
final class PageXmlAmbiguousWord {
  /// Creates the ambiguity record.
  const PageXmlAmbiguousWord({
    required this.place,
    required this.content,
    required this.candidates,
    required this.chosen,
  });

  /// Where the ambiguous unit sits in the parsed document.
  final PageXmlWordPlace place;

  /// The imported content that matched more than once.
  final String content;

  /// Every candidate `(start, end)` the bounded scan found, in document
  /// order of discovery.
  final List<(int, int)> candidates;

  /// The `(start, end)` the binding chose: the first candidate at or
  /// after the reading cursor.
  final (int, int) chosen;
}

/// The result of binding a PAGE document onto one canonical snapshot:
/// the spatial page whose zones address the target text's UTF-16
/// ranges, with the import's provenance and the full mapping outcome.
///
/// Zone rectangles are the explicitly derived bounding boxes of the
/// native polygons — the polygons themselves stay on [document], and
/// every ambiguous record addresses its source element by index. The
/// target's identity tuple travels on [targetIdentity]/
/// [targetOccurrence]/[targetProfile]/[targetTextRevision] — a host
/// that persists the binding can verify reuse against exactly the text
/// the ranges address; a changed origin or revision no longer matches.
final class PageXmlSnapshotBinding {
  const PageXmlSnapshotBinding._({
    required this.document,
    required this.target,
    required this.pages,
    required this.wordsResolved,
    required this.wordsAmbiguous,
    required this.wordsMissing,
    required this.ambiguousWords,
  });

  /// The parsed PAGE document the zones came from, with every native
  /// polygon and baseline.
  final PageXmlDocument document;

  /// The target snapshot the ranges address.
  final CanonicalTextSnapshot target;

  /// The target snapshot's publication identity — the same tuple the
  /// anchor envelope and search index verify reuse against.
  PublicationRevision get targetIdentity => target.identity;

  /// The target snapshot's section occurrence.
  SectionOccurrence get targetOccurrence => target.occurrence;

  /// The target snapshot's extraction profile.
  TextProfile get targetProfile => target.profile;

  /// The target snapshot's text revision digest.
  String get targetTextRevision => target.textRevision;

  /// One spatial page for the document's page, in a one-element list
  /// for parity with the shared contract. Rectangles are derived
  /// bounding boxes in the page's pixel space; zones address [target]'s
  /// text.
  final List<SpatialTextPage> pages;

  /// Units (words, or the line/region fallbacks) that mapped to exactly
  /// one target range.
  final int wordsResolved;

  /// Units with repeated target content or distinct OCR readings.
  final int wordsAmbiguous;

  /// Units whose content does not occur in the target text.
  final int wordsMissing;

  /// The ambiguous units with their candidate lists, in reading order.
  final List<PageXmlAmbiguousWord> ambiguousWords;

  /// Range queries over the bound page, or null when the page emitted
  /// no zones.
  SpatialZoneLookup? get lookup => pages.isEmpty ? null : SpatialZoneLookup(pages.first);

  /// The transport view of this binding.
  PageXmlBoundSpatialText get boundText => PageXmlBoundSpatialText.fromBinding(this);
}

/// The transport view of a binding: pages, outcome counts, ambiguities,
/// provenance, and the target identity tuple — everything a host needs
/// to persist or re-verify the binding without keeping the target text
/// or the parsed document resident. The worker op returns this view;
/// wire codecs encode it as structured-clone-safe maps.
final class PageXmlBoundSpatialText {
  /// Projects the full binding onto its transport view.
  PageXmlBoundSpatialText.fromBinding(final PageXmlSnapshotBinding binding)
    : pages = binding.pages,
      wordsResolved = binding.wordsResolved,
      wordsAmbiguous = binding.wordsAmbiguous,
      wordsMissing = binding.wordsMissing,
      ambiguousWords = binding.ambiguousWords,
      targetIdentity = binding.targetIdentity,
      targetOccurrence = binding.targetOccurrence,
      targetProfile = binding.targetProfile,
      targetTextRevision = binding.targetTextRevision;

  /// Rebuilds a view from its parts — the wire decoder's path.
  const PageXmlBoundSpatialText({
    required this.pages,
    required this.wordsResolved,
    required this.wordsAmbiguous,
    required this.wordsMissing,
    required this.ambiguousWords,
    required this.targetIdentity,
    required this.targetOccurrence,
    required this.targetProfile,
    required this.targetTextRevision,
  });

  /// The bound spatial pages.
  final List<SpatialTextPage> pages;

  /// Units that mapped to exactly one target range.
  final int wordsResolved;

  /// Units with repeated target content or distinct OCR readings.
  final int wordsAmbiguous;

  /// Units whose content does not occur in the target text.
  final int wordsMissing;

  /// The ambiguous units with their candidate lists, in reading order.
  final List<PageXmlAmbiguousWord> ambiguousWords;

  /// The target snapshot's publication identity.
  final PublicationRevision targetIdentity;

  /// The target snapshot's section occurrence.
  final SectionOccurrence targetOccurrence;

  /// The target snapshot's extraction profile.
  final TextProfile targetProfile;

  /// The target snapshot's text revision digest.
  final String targetTextRevision;
}

class _UnitOutcome {
  const _UnitOutcome(this.textStart, this.textEnd, this.newCursor);

  final int textStart;

  final int textEnd;

  final int newCursor;
}

/// Binds [document]'s positioned text onto [target]'s canonical text:
/// each word, line or region maps to the UTF-16 range its chosen
/// TextEquiv selects in the target, parents aggregate their children's
/// ranges, and every outcome stays observable.
///
/// The mapping runs at the finest granularity the sidecar declares —
/// words when they carry text, the line when its words do not, the
/// region when no line does. The scan walks the target text with a
/// reading cursor: a unit resolves at the first occurrence at or after
/// the cursor, falls back to the document start once when nothing
/// follows the cursor, and is missing when the content never occurs.
/// More than one occurrence makes the unit ambiguous with its full
/// candidate list — repeated quotes, alternative readings and
/// truncated scans never certify uniqueness. Astral characters and
/// diacritics compare as exact UTF-16 code units.
///
/// Throws [PageXmlException] when the projection exceeds the declared
/// work budget.
PageXmlSnapshotBinding bindPageToSnapshot({
  required final PageXmlDocument document,
  required final CanonicalTextSnapshot target,
  final PageXmlBindLimits limits = const PageXmlBindLimits(),
}) {
  limits.requireValid();
  final page = document.page;
  final text = target.text;
  var work = 0;
  var hasConfidence =
      page.confidence != null ||
      page.border?.confidence != null ||
      page.printSpace?.confidence != null;
  var wordsResolved = 0;
  var wordsAmbiguous = 0;
  var wordsMissing = 0;
  final ambiguousWords = <PageXmlAmbiguousWord>[];
  final zones = <SpatialTextZone>[];
  final storedIndex = <String, int>{
    for (var i = 0; i < page.regions.length; i++) page.regions[i].id: i,
  };
  int cursor = 0;

  int find(final String content, final int from) {
    final scanWork = text.length - from;
    if (scanWork > limits.maxProjectionWork - work) {
      throw const PageXmlException('PAGE binding exceeds the projection work budget.');
    }
    work += scanWork;
    return text.indexOf(content, from);
  }

  bool hasAlternatives(final PageXmlTextContent? content) =>
      content != null && content.alternatives.map((final item) => item.unicode).toSet().length > 1;

  // Maps one unit's content after the cursor; records every outcome.
  _UnitOutcome mapUnit({
    required final String content,
    required final bool hasAlternativeReadings,
    required final PageXmlWordPlace place,
  }) {
    if (content.isEmpty) {
      return _UnitOutcome(cursor, cursor, cursor);
    }
    var from = cursor <= text.length ? cursor : text.length;
    var found = find(content, from);
    if (found < 0 && from > 0) {
      from = 0;
      found = find(content, 0);
    }
    if (found < 0) {
      wordsMissing++;

      return _UnitOutcome(cursor, cursor, cursor);
    }
    final candidates = <(int, int)>[];
    var scan = 0;
    while (true) {
      final at = find(content, scan);
      if (at < 0) break;
      candidates.add((at, at + content.length));
      if (candidates.length >= limits.maxCandidateOccurrences) break;
      scan = at + 1;
    }
    if (candidates.length > 1 || hasAlternativeReadings) {
      wordsAmbiguous++;
      ambiguousWords.add(
        PageXmlAmbiguousWord(
          place: place,
          content: content,
          candidates: candidates,
          chosen: (found, found + content.length),
        ),
      );
    } else {
      wordsResolved++;
    }

    return _UnitOutcome(found, found + content.length, found + content.length);
  }

  void addZone(
    final SpatialZoneKind kind,
    final PageXmlPolygon polygon,
    final int start,
    final int end,
    final double? confidence,
  ) {
    if (polygon.confidence != null) hasConfidence = true;
    zones.add(
      SpatialTextZone(
        kind: kind,
        rect: polygon.boundingRect,
        textStart: start,
        textEnd: end,
        confidence: confidence,
      ),
    );
  }

  for (final region in page.regionsInReadingOrder()) {
    if (region.kind != PageXmlRegionKind.text) continue;
    final regionIndex = storedIndex[region.id]!;
    final regionConfidence = region.text?.confidence;
    final regionAlternatives = hasAlternatives(region.text);
    if (regionConfidence != null) hasConfidence = true;
    var regionStart = -1;
    var regionEnd = -1;
    var regionMapped = false;
    // Depth-first emission: the region's own zone goes out first, then
    // each line followed by that line's words.
    final lineGroups = <List<SpatialTextZone>>[];

    for (var lineIndex = 0; lineIndex < region.lines.length; lineIndex++) {
      final line = region.lines[lineIndex];
      final lineConfidence = line.text?.confidence;
      final lineAlternatives = regionAlternatives || hasAlternatives(line.text);
      if (lineConfidence != null) hasConfidence = true;
      if (line.baseline?.confidence != null) hasConfidence = true;
      var lineStart = -1;
      var lineEnd = -1;
      var lineMapped = false;
      final wordZones = <SpatialTextZone>[];

      for (var wordIndex = 0; wordIndex < line.words.length; wordIndex++) {
        final word = line.words[wordIndex];
        final wordConfidence = word.text?.confidence;
        if (wordConfidence != null) hasConfidence = true;
        final content = word.text?.text ?? '';
        // Word-level mapping only when the word itself declares text;
        // lines whose words carry none fall back to the line's own
        // content below.
        if (word.text == null || content.isEmpty) continue;
        final outcome = mapUnit(
          content: content,
          hasAlternativeReadings: lineAlternatives || hasAlternatives(word.text),
          place: PageXmlWordPlace(
            regionIndex: regionIndex,
            lineIndex: lineIndex,
            wordIndex: wordIndex,
          ),
        );
        lineMapped = true;
        lineStart = lineStart < 0 ? outcome.textStart : math.min(lineStart, outcome.textStart);
        lineEnd = lineEnd < 0 ? outcome.textEnd : math.max(lineEnd, outcome.textEnd);
        wordZones.add(_wordZone(word, outcome));
        cursor = outcome.newCursor;
      }

      if (!lineMapped && line.text != null && line.text!.text.isNotEmpty) {
        // The line's words carry no text; the line's own TextEquiv is
        // the finest declared granularity.
        final outcome = mapUnit(
          content: line.text!.text,
          hasAlternativeReadings: lineAlternatives,
          place: PageXmlWordPlace(regionIndex: regionIndex, lineIndex: lineIndex),
        );
        lineMapped = true;
        lineStart = outcome.textStart;
        lineEnd = outcome.textEnd;
        cursor = outcome.newCursor;
      }
      if (!lineMapped) continue;
      regionMapped = true;
      regionStart = regionStart < 0 ? lineStart : math.min(regionStart, lineStart);
      regionEnd = regionEnd < 0 ? lineEnd : math.max(regionEnd, lineEnd);
      lineGroups.add(<SpatialTextZone>[
        _lineZone(line, lineStart, lineEnd, lineConfidence),
        ...wordZones,
      ]);
    }

    if (!regionMapped && region.text != null && region.text!.text.isNotEmpty) {
      // A region without text-bearing lines binds its own TextEquiv —
      // the coarsest granularity real sidecars declare.
      final outcome = mapUnit(
        content: region.text!.text,
        hasAlternativeReadings: regionAlternatives,
        place: PageXmlWordPlace(regionIndex: regionIndex),
      );
      regionStart = outcome.textStart;
      regionEnd = outcome.textEnd;
      regionMapped = true;
      cursor = outcome.newCursor;
    }
    if (!regionMapped) continue;
    addZone(SpatialZoneKind.region, region.polygon, regionStart, regionEnd, regionConfidence);
    for (final group in lineGroups) {
      zones.addAll(group);
    }
  }

  final spatialPage = SpatialTextPage(
    width: page.width.toDouble(),
    height: page.height.toDouble(),
    unit: SpatialUnit.pixel,
    rotation: page.rotation,
    textLength: text.length,
    provenance: SpatialTextProvenance(
      origin: SpatialTextOrigin.importedOcr,
      hasConfidence: hasConfidence,
      softwareName: document.creator,
      softwareVersion: null,
    ),
    zones: zones,
  );

  return PageXmlSnapshotBinding._(
    document: document,
    target: target,
    pages: <SpatialTextPage>[spatialPage],
    wordsResolved: wordsResolved,
    wordsAmbiguous: wordsAmbiguous,
    wordsMissing: wordsMissing,
    ambiguousWords: ambiguousWords,
  );
}

/// A line's zone: its derived bounding box over the aggregate of its
/// children's ranges, and the line's own confidence when declared.
SpatialTextZone _lineZone(
  final PageXmlTextLine line,
  final int start,
  final int end,
  final double? confidence,
) {
  return SpatialTextZone(
    kind: SpatialZoneKind.line,
    rect: line.polygon.boundingRect,
    textStart: start,
    textEnd: end,
    confidence: confidence,
  );
}

/// A word's zone: its derived bounding box, the mapped range, and the
/// word's own confidence when declared.
SpatialTextZone _wordZone(final PageXmlWord word, final _UnitOutcome outcome) {
  return SpatialTextZone(
    kind: SpatialZoneKind.word,
    rect: word.polygon.boundingRect,
    textStart: outcome.textStart,
    textEnd: outcome.textEnd,
    confidence: word.text?.confidence,
  );
}
