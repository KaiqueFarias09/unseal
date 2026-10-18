import 'dart:math' as math;

import '../../foundation/spatial/spatial_text_page.dart';
import '../../foundation/spatial/spatial_text_zone.dart';
import '../../foundation/spatial/spatial_unit.dart';
import '../../foundation/spatial/spatial_zone_lookup.dart';
import '../../foundation/text/canonical_text_snapshot.dart';
import '../../foundation/text/publication_revision.dart';
import '../../foundation/text/section_occurrence.dart';
import '../../foundation/text/text_profile.dart';
import 'hocr_document.dart';
import 'hocr_exception.dart';

/// Work bounds of one hOCR-to-snapshot binding. The projection scan is
/// linear in the target text per searched unit; the budget keeps a hostile
/// document from quadratic work and reports the refusal typed.
final class HocrBindLimits {
  /// Creates the limits.
  const HocrBindLimits({
    this.maxCandidateOccurrences = 16,
    this.maxProjectionWork = 64 * 1024 * 1024,
  });

  /// Validates the declared limits; [ArgumentError] reports values the
  /// binding cannot serve.
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

  /// How many occurrences (at least two) of one unit's content the mapping
  /// records as ambiguity candidates before it stops counting.
  final int maxCandidateOccurrences;

  /// The total characters one binding may scan across all its searches.
  final int maxProjectionWork;
}

/// Where a mapped unit sits in the parsed document: the page, the line's
/// index among that page's lines in document order, and the word's index
/// inside its line — null for a line-level unit.
final class HocrUnitPlace {
  /// Creates the place.
  const HocrUnitPlace({required this.pageIndex, required this.lineIndex, this.wordIndex});

  /// The page's index in [HocrDocument.pages].
  final int pageIndex;

  /// The line's index in [HocrPage.lines].
  final int lineIndex;

  /// The word's index in [HocrLine.words], when the unit is a word.
  final int? wordIndex;
}

/// One ambiguous mapped unit: its place and the bounded candidate ranges
/// the target text offers. An alternative reading on the unit or an
/// ancestor makes it ambiguous even with one target candidate.
final class HocrAmbiguousUnit {
  /// Creates the ambiguity record.
  const HocrAmbiguousUnit({
    required this.place,
    required this.content,
    required this.candidates,
    required this.chosen,
  });

  /// Where the unit sits in the parsed document.
  final HocrUnitPlace place;

  /// The imported content that matched more than once or carried
  /// alternatives.
  final String content;

  /// Every candidate `(start, end)` the bounded scan found, in document
  /// order of discovery.
  final List<(int, int)> candidates;

  /// The `(start, end)` the binding chose: the first candidate at or
  /// after the reading cursor.
  final (int, int) chosen;
}

/// The result of binding an hOCR document onto one canonical snapshot:
/// the spatial pages whose zones address the target text's UTF-16 ranges,
/// with the import's provenance and the full mapping outcome.
///
/// Pages without a spatial frame (see [HocrFrameSource.none]) bind their
/// text but emit no spatial page; [pageIndexes] names the document page
/// each entry of [pages] projects. The target's identity tuple travels on
/// [targetIdentity]/[targetOccurrence]/[targetProfile]/[targetTextRevision]
/// so a host that persists the binding can verify reuse against exactly
/// the text the ranges address.
final class HocrSnapshotBinding {
  const HocrSnapshotBinding._({
    required this.document,
    required this.target,
    required this.pages,
    required this.pageIndexes,
    required this.wordsResolved,
    required this.wordsAmbiguous,
    required this.wordsMissing,
    required this.ambiguousUnits,
  });

  /// The parsed document the zones came from, with every native box,
  /// baseline and property.
  final HocrDocument document;

  /// The target snapshot the ranges address.
  final CanonicalTextSnapshot target;

  /// The target snapshot's publication identity.
  PublicationRevision get targetIdentity => target.identity;

  /// The target snapshot's section occurrence.
  SectionOccurrence get targetOccurrence => target.occurrence;

  /// The target snapshot's extraction profile.
  TextProfile get targetProfile => target.profile;

  /// The target snapshot's text revision digest.
  String get targetTextRevision => target.textRevision;

  /// One spatial page per document page that has a frame, in document
  /// order. Rectangles are the declared boxes in the page's pixel space;
  /// zones address [target]'s text.
  final List<SpatialTextPage> pages;

  /// The index in [HocrDocument.pages] of each entry of [pages].
  final List<int> pageIndexes;

  /// Units (words, or line fallbacks) that mapped to exactly one target
  /// range.
  final int wordsResolved;

  /// Units with repeated target content or alternative readings.
  final int wordsAmbiguous;

  /// Units whose content does not occur in the target text.
  final int wordsMissing;

  /// The ambiguous units with their candidate lists, in document order.
  final List<HocrAmbiguousUnit> ambiguousUnits;

  /// Range queries over the bound pages, one per entry of [pages].
  List<SpatialZoneLookup> get lookups => <SpatialZoneLookup>[
    for (final page in pages) SpatialZoneLookup(page),
  ];

  /// The transport view of this binding.
  HocrBoundSpatialText get boundText => HocrBoundSpatialText.fromBinding(this);
}

/// The transport view of a binding: pages, their document page indexes,
/// outcome counts, ambiguities, and the target identity tuple — everything
/// a host needs to persist or re-verify the binding without keeping the
/// target text or the parsed document resident. The worker op returns this
/// view; wire codecs encode it as structured-clone-safe maps.
final class HocrBoundSpatialText {
  /// Projects the full binding onto its transport view.
  HocrBoundSpatialText.fromBinding(final HocrSnapshotBinding binding)
    : pages = binding.pages,
      pageIndexes = binding.pageIndexes,
      wordsResolved = binding.wordsResolved,
      wordsAmbiguous = binding.wordsAmbiguous,
      wordsMissing = binding.wordsMissing,
      ambiguousUnits = binding.ambiguousUnits,
      targetIdentity = binding.targetIdentity,
      targetOccurrence = binding.targetOccurrence,
      targetProfile = binding.targetProfile,
      targetTextRevision = binding.targetTextRevision;

  /// Rebuilds a view from its parts — the wire decoder's path.
  const HocrBoundSpatialText({
    required this.pages,
    required this.pageIndexes,
    required this.wordsResolved,
    required this.wordsAmbiguous,
    required this.wordsMissing,
    required this.ambiguousUnits,
    required this.targetIdentity,
    required this.targetOccurrence,
    required this.targetProfile,
    required this.targetTextRevision,
  });

  /// The bound spatial pages.
  final List<SpatialTextPage> pages;

  /// The document page index of each entry of [pages].
  final List<int> pageIndexes;

  /// Units that mapped to exactly one target range.
  final int wordsResolved;

  /// Units with repeated target content or alternative readings.
  final int wordsAmbiguous;

  /// Units whose content does not occur in the target text.
  final int wordsMissing;

  /// The ambiguous units with their candidate lists, in document order.
  final List<HocrAmbiguousUnit> ambiguousUnits;

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

/// The content a unit binds: its model [text] without leading and trailing
/// ASCII whitespace (space, tab, LF, CR, FF). Non-ASCII spaces such as
/// U+00A0 are content and stay. Empty means the unit binds nothing.
String bindableContent(final String text) {
  var start = 0;
  var end = text.length;
  while (start < end && _isAsciiSpace(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isAsciiSpace(text.codeUnitAt(end - 1))) {
    end--;
  }

  return start == 0 && end == text.length ? text : text.substring(start, end);
}

bool _isAsciiSpace(final int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C;

/// Binds [document]'s positioned text onto [target]'s canonical text:
/// each word maps to the UTF-16 range its text selects in the target,
/// lines whose words carry no text map their own text, parents aggregate
/// their children's ranges, and every outcome stays observable.
///
/// The scan walks the target text with one reading cursor across all
/// pages in document order: a unit resolves at the first occurrence at or
/// after the cursor, falls back to the document start once when nothing
/// follows the cursor, and is missing when the content never occurs. More
/// than one occurrence, or an alternative reading on the unit or an
/// ancestor, makes the unit ambiguous with its bounded candidate list —
/// repeated quotes, alternative readings and truncated scans never
/// certify uniqueness. Astral characters and diacritics compare as exact
/// UTF-16 code units.
///
/// The region zone of a line is its nearest boxed ancestor among
/// paragraph, block and page frame (the DjVu rule for skipped levels);
/// words without a box bind but emit no zone; pages without a frame emit
/// no spatial page.
///
/// Throws [HocrException] when the projection exceeds the declared work
/// budget.
HocrSnapshotBinding bindHocrToSnapshot({
  required final HocrDocument document,
  required final CanonicalTextSnapshot target,
  final HocrBindLimits limits = const HocrBindLimits(),
}) {
  limits.requireValid();
  final text = target.text;
  var work = 0;
  var wordsResolved = 0;
  var wordsAmbiguous = 0;
  var wordsMissing = 0;
  final ambiguousUnits = <HocrAmbiguousUnit>[];
  final spatialPages = <SpatialTextPage>[];
  final pageIndexes = <int>[];
  var cursor = 0;

  int find(final String content, final int from) {
    final scanWork = text.length - from;
    if (scanWork > limits.maxProjectionWork - work) {
      throw const HocrException('hOCR binding exceeds the projection work budget.');
    }
    work += scanWork;

    return text.indexOf(content, from);
  }

  _UnitOutcome mapUnit({
    required final String content,
    required final bool hasAlternativeReadings,
    required final HocrUnitPlace place,
  }) {
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
      ambiguousUnits.add(
        HocrAmbiguousUnit(
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

  for (var pageIndex = 0; pageIndex < document.pages.length; pageIndex++) {
    final page = document.pages[pageIndex];
    final frame = page.frame;
    final zones = <SpatialTextZone>[];
    var hasConfidence = false;
    var lineIndex = 0;
    // Consecutive lines sharing a region buffer until the region changes,
    // so the region zone can carry the aggregate of its lines' ranges and
    // still precede them in the depth-first order.
    HocrElement? openRegion;
    var regionStart = -1;
    var regionEnd = -1;
    final regionLines = <List<SpatialTextZone>>[];

    void flushRegion() {
      final region = openRegion;
      if (region == null || regionLines.isEmpty) {
        openRegion = null;
        regionLines.clear();

        return;
      }
      final box = region is HocrPage ? frame! : region.box!;
      zones.add(
        SpatialTextZone(
          kind: SpatialZoneKind.region,
          rect: box.rect,
          textStart: regionStart,
          textEnd: regionEnd,
        ),
      );
      for (final group in regionLines) {
        zones.addAll(group);
      }
      openRegion = null;
      regionLines.clear();
    }

    void visitLine(final HocrLine line, final HocrElement? region) {
      final currentLine = lineIndex++;
      final lineAlternatives = line.hasAlternativeReadings;
      var lineStart = -1;
      var lineEnd = -1;
      var lineMapped = false;
      final wordZones = <SpatialTextZone>[];
      for (var wordIndex = 0; wordIndex < line.words.length; wordIndex++) {
        final word = line.words[wordIndex];
        final confidence = word.confidence;
        if (confidence != null && !confidence.isUnknown) hasConfidence = true;
        final content = bindableContent(word.text);
        if (content.isEmpty) continue;
        final outcome = mapUnit(
          content: content,
          hasAlternativeReadings: lineAlternatives || word.hasAlternativeReadings,
          place: HocrUnitPlace(pageIndex: pageIndex, lineIndex: currentLine, wordIndex: wordIndex),
        );
        lineMapped = true;
        lineStart = lineStart < 0 ? outcome.textStart : math.min(lineStart, outcome.textStart);
        lineEnd = lineEnd < 0 ? outcome.textEnd : math.max(lineEnd, outcome.textEnd);
        cursor = outcome.newCursor;
        final wordBox = word.box;
        if (wordBox != null) {
          wordZones.add(
            SpatialTextZone(
              kind: SpatialZoneKind.word,
              rect: wordBox.rect,
              textStart: outcome.textStart,
              textEnd: outcome.textEnd,
              confidence: confidence?.shared,
            ),
          );
        }
      }
      if (!lineMapped) {
        final content = bindableContent(line.text);
        if (content.isNotEmpty) {
          final outcome = mapUnit(
            content: content,
            hasAlternativeReadings: lineAlternatives,
            place: HocrUnitPlace(pageIndex: pageIndex, lineIndex: currentLine),
          );
          lineMapped = true;
          lineStart = outcome.textStart;
          lineEnd = outcome.textEnd;
          cursor = outcome.newCursor;
        }
      }
      if (!lineMapped || region == null) return;
      if (!identical(openRegion, region)) {
        flushRegion();
        openRegion = region;
        regionStart = lineStart;
        regionEnd = lineEnd;
      } else {
        regionStart = math.min(regionStart, lineStart);
        regionEnd = math.max(regionEnd, lineEnd);
      }
      regionLines.add(<SpatialTextZone>[
        SpatialTextZone(
          kind: SpatialZoneKind.line,
          rect: line.box.rect,
          textStart: lineStart,
          textEnd: lineEnd,
        ),
        ...wordZones,
      ]);
    }

    void visit(final List<HocrElement> nodes, final HocrElement? region) {
      for (final node in nodes) {
        switch (node) {
          case HocrBlock():
            visit(node.children, node);
          case HocrParagraph():
            visit(node.children, node.box == null ? region : node);
          case HocrLine():
            visitLine(node, region);
          case HocrPage():
          case HocrWord():
            break;
        }
      }
    }

    visit(page.children, frame == null ? null : page);
    flushRegion();
    if (frame == null) continue;
    spatialPages.add(
      SpatialTextPage(
        width: frame.x1.toDouble(),
        height: frame.y1.toDouble(),
        unit: SpatialUnit.pixel,
        rotation: 0,
        textLength: text.length,
        provenance: SpatialTextProvenance(
          origin: SpatialTextOrigin.importedOcr,
          hasConfidence: hasConfidence,
          softwareName: document.system,
          softwareVersion: null,
        ),
        zones: zones,
      ),
    );
    pageIndexes.add(pageIndex);
  }

  return HocrSnapshotBinding._(
    document: document,
    target: target,
    pages: spatialPages,
    pageIndexes: pageIndexes,
    wordsResolved: wordsResolved,
    wordsAmbiguous: wordsAmbiguous,
    wordsMissing: wordsMissing,
    ambiguousUnits: ambiguousUnits,
  );
}
