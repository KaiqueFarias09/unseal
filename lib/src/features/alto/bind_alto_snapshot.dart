import 'dart:math' as math;

import '../../foundation/spatial/spatial_rect.dart';
import '../../foundation/spatial/spatial_text_page.dart';
import '../../foundation/spatial/spatial_text_zone.dart';
import '../../foundation/spatial/spatial_zone_lookup.dart';
import '../../foundation/text/canonical_text_snapshot.dart';
import '../../foundation/text/publication_revision.dart';
import '../../foundation/text/section_occurrence.dart';
import '../../foundation/text/text_profile.dart';
import 'alto_document.dart';
import 'alto_exception.dart';
import 'alto_scale.dart';

/// Work bounds of one ALTO-to-snapshot binding. The projection scan is
/// linear in the target text per searched word; the budget keeps a
/// hostile document from quadratic work and reports the refusal typed.
final class AltoBindLimits {
  /// Creates the limits.
  const AltoBindLimits({
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

  /// How many occurrences (at least two) of one word's content the mapping records as
  /// ambiguity candidates before it stops counting.
  final int maxCandidateOccurrences;

  /// The total characters one binding may scan across all its word
  /// searches.
  final int maxProjectionWork;
}

/// One ambiguous word: its place in the imported document and every
/// candidate range the target text offers.
final class AltoAmbiguousWord {
  /// Creates the ambiguity record.
  const AltoAmbiguousWord({
    required this.pageIndex,
    required this.blockIndex,
    required this.lineIndex,
    required this.wordIndex,
    required this.content,
    required this.candidates,
    required this.chosen,
  });

  /// The zero-based page the ambiguous word sits on.
  final int pageIndex;

  /// The zero-based text block holding the word.
  final int blockIndex;

  /// The zero-based line holding the word.
  final int lineIndex;

  /// The zero-based word inside its line.
  final int wordIndex;

  /// The imported content that matched more than once.
  final String content;

  /// Every candidate `(start, end)` the bounded scan found, in document
  /// order of discovery.
  final List<(int, int)> candidates;

  /// The `(start, end)` the binding chose: the first candidate at or
  /// after the reading cursor.
  final (int, int) chosen;
}

/// The result of binding an ALTO document onto one canonical snapshot:
/// spatial pages whose zones address the target text's UTF-16 ranges,
/// with the import's provenance and the full mapping outcome.
///
/// The binding maps text only; rectangle conversion stays a separate,
/// explicitly scaled step ([AltoScale]), so a physical-unit document
/// binds without pretending its millimetres are pixels. The target's
/// identity tuple travels on [targetIdentity]/[targetOccurrence]/
/// [targetProfile]/[targetTextRevision] — a host that persists the
/// binding can verify reuse against exactly the text the ranges address.
final class AltoSnapshotBinding {
  const AltoSnapshotBinding._({
    required this.document,
    required this.target,
    required this.pages,
    required this.wordsResolved,
    required this.wordsAmbiguous,
    required this.wordsMissing,
    required this.ambiguousWords,
  });

  /// The parsed ALTO document the zones came from.
  final AltoDocument document;

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

  /// One spatial page per ALTO page, in document order. Rectangles keep
  /// the document's declared unit; zones address [target]'s text.
  final List<SpatialTextPage> pages;

  /// Words that mapped to exactly one target range.
  final int wordsResolved;

  /// Words whose content occurs more than once in the target text.
  final int wordsAmbiguous;

  /// Words whose content does not occur in the target text.
  final int wordsMissing;

  /// The ambiguous words with their candidate lists, in document order.
  final List<AltoAmbiguousWord> ambiguousWords;

  /// Range queries over the bound pages, one per page in order.
  List<SpatialZoneLookup> get lookups => <SpatialZoneLookup>[
    for (final page in pages) SpatialZoneLookup(page),
  ];

  /// The transport view of this binding.
  AltoBoundSpatialText get boundText => AltoBoundSpatialText.fromBinding(this);
}

/// The transport view of a binding: pages, outcome counts, ambiguities,
/// provenance, and the target identity tuple — everything a host needs
/// to persist or re-verify the binding without keeping the target text
/// or the parsed document resident. The worker ops return this view;
/// wire codecs encode it as structured-clone-safe maps.
final class AltoBoundSpatialText {
  /// Projects the full binding onto its transport view.
  AltoBoundSpatialText.fromBinding(final AltoSnapshotBinding binding)
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
  const AltoBoundSpatialText({
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

  /// One spatial page per ALTO page, in document order. Rectangles keep
  /// the document's declared unit; zones address the target text.
  final List<SpatialTextPage> pages;

  /// Words that mapped to exactly one target range.
  final int wordsResolved;

  /// Words whose content occurs more than once in the target text.
  final int wordsAmbiguous;

  /// Words whose content does not occur in the target text.
  final int wordsMissing;

  /// The ambiguous words with their candidate lists, in document order.
  final List<AltoAmbiguousWord> ambiguousWords;

  /// The target snapshot's publication identity.
  final PublicationRevision targetIdentity;

  /// The target snapshot's section occurrence.
  final SectionOccurrence targetOccurrence;

  /// The target snapshot's extraction profile.
  final TextProfile targetProfile;

  /// The target snapshot's text revision digest.
  final String targetTextRevision;
}

class _WordOutcome {
  const _WordOutcome(this.zone, this.newCursor);

  final SpatialTextZone zone;
  final int newCursor;
}

/// Binds [document]'s positioned words onto [target]'s canonical text:
/// each ALTO `String` maps to the UTF-16 range its content selects in
/// the target, lines and text blocks aggregate their children's ranges,
/// and every outcome stays observable.
///
/// The scan walks the target text with a reading cursor: a word resolves
/// at the first occurrence at or after the cursor, falls back to the
/// document start once when nothing follows the cursor, and is missing
/// when the content never occurs. More than one occurrence makes the
/// word ambiguous with its full candidate list — the binding never
/// silently picks between indistinguishable hits. Repeated quotes, astral
/// characters and diacritics compare as exact UTF-16 code units.
///
/// Throws [AltoException] when the projection exceeds the declared
/// work budget.
AltoSnapshotBinding bindAltoToSnapshot({
  required final AltoDocument document,
  required final CanonicalTextSnapshot target,
  final AltoBindLimits limits = const AltoBindLimits(),
}) {
  limits.requireValid();
  final text = target.text;
  var work = 0;
  var hasConfidence = false;
  var wordsResolved = 0;
  var wordsAmbiguous = 0;
  var wordsMissing = 0;
  final ambiguousWords = <AltoAmbiguousWord>[];
  final pageZoneLists = <List<SpatialTextZone>>[];

  for (var pageIndex = 0; pageIndex < document.pages.length; pageIndex++) {
    final altoPage = document.pages[pageIndex];
    final zones = <SpatialTextZone>[];
    var cursor = 0;

    // Depth-first emission: a text block emits its region header first,
    // then each line followed by that line's words.
    (int, int, List<SpatialTextZone>) mapLine(
      final AltoLine line,
      final int blockIndex,
      final int lineIndex,
    ) {
      if (line.confidence != null) hasConfidence = true;
      final wordZones = <SpatialTextZone>[];
      var lineStart = -1;
      var lineEnd = -1;
      for (var wordIndex = 0; wordIndex < line.strings.length; wordIndex++) {
        final outcome = _mapWord(
          word: line.strings[wordIndex],
          text: text,
          cursor: cursor,
          limits: limits,
          chargeWork: (final used) => work += used,
          onResolved: () => wordsResolved++,
          onAmbiguous: (final recorded) {
            wordsAmbiguous++;
            ambiguousWords.add(recorded);
          },
          onMissing: () => wordsMissing++,
          pageIndex: pageIndex,
          blockIndex: blockIndex,
          lineIndex: lineIndex,
          wordIndex: wordIndex,
        );
        cursor = outcome.newCursor;
        if (outcome.zone.textEnd > outcome.zone.textStart) {
          // A block's lines need not map in monotonic target order, so
          // the aggregate span covers its words with min and max.
          lineStart = lineStart < 0
              ? outcome.zone.textStart
              : math.min(lineStart, outcome.zone.textStart);
          lineEnd = lineEnd < 0 ? outcome.zone.textEnd : math.max(lineEnd, outcome.zone.textEnd);
        }
        wordZones.add(outcome.zone);
      }

      return (lineStart, lineEnd, wordZones);
    }

    void walkBlocks(final List<AltoBlock> blocks) {
      for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
        final block = blocks[blockIndex];
        // Composed blocks carry nested text blocks; the reading-order
        // walk descends and binds whatever text it finds there.
        if (block.children.isNotEmpty) walkBlocks(block.children);
        if (block.kind != AltoBlockKind.text) continue;
        final lineGroups = <List<SpatialTextZone>>[];
        var blockStart = -1;
        var blockEnd = -1;
        for (var lineIndex = 0; lineIndex < block.lines.length; lineIndex++) {
          final line = block.lines[lineIndex];
          final (lineStart, lineEnd, wordZones) = mapLine(line, blockIndex, lineIndex);
          if (lineStart < 0) continue;
          lineGroups.add(<SpatialTextZone>[
            _zoneOf(SpatialZoneKind.line, line.rect, lineStart, lineEnd, line.confidence),
            ...wordZones,
          ]);
          blockStart = blockStart < 0 ? lineStart : math.min(blockStart, lineStart);
          blockEnd = blockEnd < 0 ? lineEnd : math.max(blockEnd, lineEnd);
        }
        if (blockStart < 0) continue;
        zones.add(_zoneOf(SpatialZoneKind.region, block.rect, blockStart, blockEnd, null));
        for (final group in lineGroups) {
          zones.addAll(group);
        }
      }
    }

    walkBlocks(altoPage.blocks);

    pageZoneLists.add(zones);
  }

  final pages = <SpatialTextPage>[
    for (var pageIndex = 0; pageIndex < document.pages.length; pageIndex++)
      SpatialTextPage(
        width: document.pages[pageIndex].width,
        height: document.pages[pageIndex].height,
        unit: document.unit,
        rotation: 0,
        textLength: text.length,
        provenance: SpatialTextProvenance(
          origin: SpatialTextOrigin.importedOcr,
          hasConfidence: hasConfidence,
          softwareName: document.softwareName,
          softwareVersion: document.softwareVersion,
        ),
        zones: pageZoneLists[pageIndex],
      ),
  ];

  return AltoSnapshotBinding._(
    document: document,
    target: target,
    pages: pages,
    wordsResolved: wordsResolved,
    wordsAmbiguous: wordsAmbiguous,
    wordsMissing: wordsMissing,
    ambiguousWords: ambiguousWords,
  );
}

_WordOutcome _mapWord({
  required final AltoString word,
  required final String text,
  required final int cursor,
  required final AltoBindLimits limits,
  required final int Function(int used) chargeWork,
  required final void Function() onResolved,
  required final void Function(AltoAmbiguousWord recorded) onAmbiguous,
  required final void Function() onMissing,
  required final int pageIndex,
  required final int blockIndex,
  required final int lineIndex,
  required final int wordIndex,
}) {
  if (word.content.isEmpty) {
    return _WordOutcome(
      _zoneOf(SpatialZoneKind.word, word.rect, cursor, cursor, word.confidence),
      cursor,
    );
  }
  var from = cursor <= text.length ? cursor : text.length;
  var found = text.indexOf(word.content, from);
  if (found < 0 && from > 0) {
    from = 0;
    found = text.indexOf(word.content);
  }
  final totalWork = chargeWork(text.length - from);
  if (totalWork > limits.maxProjectionWork) {
    throw const AltoException('ALTO binding exceeds the projection work budget.');
  }
  if (found < 0) {
    onMissing();

    return _WordOutcome(
      _zoneOf(SpatialZoneKind.word, word.rect, cursor, cursor, word.confidence),
      cursor,
    );
  }
  final candidates = <(int, int)>[];
  var scan = 0;
  while (true) {
    final at = text.indexOf(word.content, scan);
    if (at < 0) break;
    candidates.add((at, at + word.content.length));
    if (candidates.length >= limits.maxCandidateOccurrences) break;
    scan = at + 1;
  }
  if (candidates.length > 1) {
    onAmbiguous(
      AltoAmbiguousWord(
        pageIndex: pageIndex,
        blockIndex: blockIndex,
        lineIndex: lineIndex,
        wordIndex: wordIndex,
        content: word.content,
        candidates: candidates,
        chosen: (found, found + word.content.length),
      ),
    );
  } else {
    onResolved();
  }

  return _WordOutcome(
    _zoneOf(SpatialZoneKind.word, word.rect, found, found + word.content.length, word.confidence),
    found + word.content.length,
  );
}

SpatialTextZone _zoneOf(
  final SpatialZoneKind kind,
  final SpatialRect rect,
  final int start,
  final int end,
  final double? confidence,
) {
  return SpatialTextZone(
    kind: kind,
    rect: rect,
    textStart: start,
    textEnd: end,
    confidence: confidence,
  );
}
