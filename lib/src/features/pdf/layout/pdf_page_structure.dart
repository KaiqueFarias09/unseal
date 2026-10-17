import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../../foundation/text/canonical_text_snapshot.dart';
import '../../../foundation/text/publication_revision.dart';
import '../../../foundation/text/revision_digest.dart';
import '../../../foundation/text/section_occurrence.dart';
import '../../../foundation/text/text_profile.dart';
import '../entities/pdf_layout.dart';
import '../entities/pdf_page.dart';
import '../entities/pdf_page_text.dart';
import '../entities/pdf_position.dart';
import '../reflow/pdf_reflow.dart';
import 'pdf_layout_segmentation.dart';
import 'pdf_reading_order.dart';
import 'pdf_table_detector.dart';

/// The extraction profile of the source space: the page's raw line
/// list before any reflow decision. Bump the revision seed only when
/// the extractor's source-space output changes shape — every anchor
/// minted before becomes unverifiable by design.
const String _sourceExtractionRevisionSeed = 'unseal pdf source-line extraction 1';

/// Computes the `sha256:`-prefixed revision of a reflow plan: the
/// plan's decisions hashed bit-exactly, so the full-document plan and
/// a session's sampled plan carry different revisions whenever they
/// differ at all — never the same revision by convenience.
String pdfPlanRevision(final PdfReflowPlan plan) {
  final values = <double>[
    plan.headerSkip,
    plan.footerSkip,
    plan.dominantFontSize,
    plan.stats.top,
    plan.stats.bottom,
    plan.stats.right,
    plan.stats.lineSpace,
    plan.stats.paraSpace,
    plan.stats.leftMinOdd,
    plan.stats.leftMaxOdd,
    plan.stats.indentMinOdd,
    plan.stats.indentMaxOdd,
    plan.stats.leftMinEven,
    plan.stats.leftMaxEven,
    plan.stats.indentMinEven,
    plan.stats.indentMaxEven,
  ];
  final bytes = ByteData(values.length * 8);
  for (var i = 0; i < values.length; i++) {
    bytes.setFloat64(i * 8, values[i], Endian.little);
  }

  return RevisionDigest.hex(SHA256Digest().process(_bytesOf(bytes)));
}

Uint8List _bytesOf(final ByteData data) =>
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

/// The stable structure of one PDF page: words, blocks, columns and
/// tables with verifiable geometry, the page's source lines, and the
/// mapping from source positions to a canonical text.
///
/// The structure separates three spaces, per C04 of the parallel plan:
/// the **source space** (the extractor's own line list — stable for
/// the same file revision and extractor), the **canonical text** (the
/// post-reflow text a reading mode serves — plan-dependent), and the
/// **reading order** (blocks in sequence). Anchors live in the source
/// space and map into any canonical text, which is what survives
/// reopenings and full-document ↔ session-sample mode switches.
final class PdfPageStructure {
  PdfPageStructure._({
    required this.pageIndex,
    required this.pageCount,
    required this.geometry,
    required this.sourceLines,
    required this.words,
    required this.blocks,
    required this.columns,
    required this.tableRegion,
    required this.tableUnsupported,
    required this.canonicalText,
    required this.canonicalProfile,
    required this.canonicalLineSources,
    required this.readingOrderPaths,
    required final List<int?> wordLineIndexes,
    required final List<(int, int)?> wordRanges,
  }) : _canonicalLinePrefix = _prefixOf(canonicalText),
       _wordLineIndexes = wordLineIndexes,
       _wordRanges = wordRanges;

  /// Builds the structure of one page from its extraction parts.
  ///
  /// [sourceLines] is the raw extraction's line list; [canonical] the
  /// post-reflow page text under the plan whose digest is
  /// [planRevision]. [canonicalScope] names the plan's scope
  /// (`document` for the whole-document plan, `session-sample` for a
  /// sampled one) and joins the canonical profile id, so the two
  /// reading modes never share a text profile.
  factory PdfPageStructure.build({
    required final int pageIndex,
    required final int pageCount,
    required final PdfPageGeometry geometry,
    required final List<PdfTextLine> sourceLines,
    required final List<PdfWord> words,
    required final List<PdfRuleLine> rules,
    required final PdfPageText canonical,
    required final String canonicalScope,
    required final String planRevision,
    final double headerSkip = 0,
    final double footerSkip = 0,
    final List<(String, bool)>? readingOrder,
  }) {
    final (segmentLines, segmentBlocks) = PdfLayoutSegmentation.segment(words);
    final (orderedBlocks, columnRegions) = PdfReadingOrder.order(
      segmentBlocks,
      pageWidth: geometry.width,
      headerSkip: headerSkip,
      footerSkip: footerSkip,
    );

    final wordLineIndexes = List<int?>.filled(words.length, null);
    final wordRanges = List<(int, int)?>.filled(words.length, null);
    _associateWordsToSourceLines(words, sourceLines, wordLineIndexes, wordRanges);

    final roleSourceIndexes = <List<int>>[];
    final blockTexts = <String>[];
    for (final block in orderedBlocks) {
      final indexes = <int>[];
      final lineTexts = <String>[];
      for (final line in block.lines) {
        final lineIndexes = <int>{};
        for (final word in line.words) {
          final wordIndex = words.indexOf(word);
          if (wordIndex < 0) continue;
          final lineIndex = wordLineIndexes[wordIndex];
          if (lineIndex != null) lineIndexes.add(lineIndex);
        }
        indexes.addAll(lineIndexes);
        lineTexts.add(line.text);
      }
      roleSourceIndexes.add(indexes);
      blockTexts.add(lineTexts.join('\n'));
    }

    final blocks = <PdfTextBlock>[
      for (var i = 0; i < orderedBlocks.length; i++)
        PdfTextBlock(
          index: i,
          text: blockTexts[i],
          x: orderedBlocks[i].x,
          y: orderedBlocks[i].y,
          width: orderedBlocks[i].width,
          height: orderedBlocks[i].height,
          role: _roleOf(orderedBlocks[i], headerSkip: headerSkip, footerSkip: footerSkip),
          sourceLineIndexes: roleSourceIndexes[i],
        ),
    ];

    final (tableRegion, tableUnsupported) = PdfTableDetector.detect(
      rules: rules,
      words: words,
      pageWidth: geometry.width,
      pageHeight: geometry.height,
    );

    final canonicalLineSources = _alignCanonicalToSource(canonical.lines, sourceLines);

    return PdfPageStructure._(
      pageIndex: pageIndex,
      pageCount: pageCount,
      geometry: geometry,
      sourceLines: List.of(sourceLines),
      words: List.of(words),
      blocks: blocks,
      columns: columnRegions,
      tableRegion: tableRegion,
      tableUnsupported: tableUnsupported,
      canonicalText: canonical.text,
      canonicalProfile: TextProfile.of(
        algorithm: 'pdf.reflow',
        options: <String, String>{'scope': canonicalScope},
        planRevision: planRevision,
      ),
      canonicalLineSources: canonicalLineSources,
      readingOrderPaths:
          readingOrder ??
          <(String, bool)>[for (var i = 1; i <= pageCount; i++) ('page_$i.html', true)],
      wordLineIndexes: wordLineIndexes,
      wordRanges: wordRanges,
    );
  }

  /// Rebuilds a structure from already-computed parts — the wire
  /// decoder's path. Validates the alignment arrays against the
  /// payload they describe; [ArgumentError] reports inconsistencies.
  factory PdfPageStructure.restore({
    required final int pageIndex,
    required final int pageCount,
    required final PdfPageGeometry geometry,
    required final List<PdfTextLine> sourceLines,
    required final List<PdfWord> words,
    required final List<PdfTextBlock> blocks,
    required final List<PdfColumnRegion> columns,
    required final PdfTableRegion? tableRegion,
    required final PdfTableUnsupported? tableUnsupported,
    required final String canonicalText,
    required final TextProfile canonicalProfile,
    required final List<int> canonicalLineSources,
    required final List<int?> wordLineIndexes,
    required final List<(int, int)?> wordRanges,
    required final List<(String, bool)> readingOrderPaths,
  }) {
    final canonicalLineCount = canonicalText.isEmpty ? 0 : canonicalText.split('\n').length;
    if (canonicalLineSources.length != canonicalLineCount) {
      throw ArgumentError(
        'canonicalLineSources (${canonicalLineSources.length}) does not match '
        'the canonical text line count ($canonicalLineCount)',
      );
    }
    if (wordLineIndexes.length != words.length || wordRanges.length != words.length) {
      throw ArgumentError('Word provenance arrays must align with the word list');
    }

    return PdfPageStructure._(
      pageIndex: pageIndex,
      pageCount: pageCount,
      geometry: geometry,
      sourceLines: List.of(sourceLines),
      words: List.of(words),
      blocks: List.of(blocks),
      columns: List.of(columns),
      tableRegion: tableRegion,
      tableUnsupported: tableUnsupported,
      canonicalText: canonicalText,
      canonicalProfile: canonicalProfile,
      canonicalLineSources: List.of(canonicalLineSources),
      readingOrderPaths: List.of(readingOrderPaths),
      wordLineIndexes: wordLineIndexes,
      wordRanges: wordRanges,
    );
  }

  /// The zero-based page index this structure describes.
  final int pageIndex;

  /// The document's page count.
  final int pageCount;

  /// The page's visible geometry and the affine back to PDF space.
  final PdfPageGeometry geometry;

  /// The source space: the extraction's own line list, pre-reflow.
  final List<PdfTextLine> sourceLines;

  /// The page's words, from real glyph advances.
  final List<PdfWord> words;

  /// The page's blocks in reading order.
  final List<PdfTextBlock> blocks;

  /// The detected column regions; empty on single-column pages.
  final List<PdfColumnRegion> columns;

  /// The detected table region, when the page yields one.
  final PdfTableRegion? tableRegion;

  /// The refused table diagnosis, when a table-shaped area did not
  /// survive detection.
  final PdfTableUnsupported? tableUnsupported;

  /// The canonical text of the page under the structure's profile.
  final String canonicalText;

  /// The profile the canonical text was produced under: reflow
  /// algorithm, plan scope and the plan revision itself.
  final TextProfile canonicalProfile;

  /// Per canonical line: the source line index it came from; null
  /// entries never occur — dropped lines simply have no entry here,
  /// and the inverse lives in [_sourceToCanonical].
  final List<int> canonicalLineSources;

  /// The document reading order the occurrence revision digests.
  final List<(String, bool)> readingOrderPaths;

  final List<int?> _wordLineIndexes;
  final List<(int, int)?> _wordRanges;
  late final Map<int, int> _sourceToCanonical = <int, int>{
    for (var i = 0; i < canonicalLineSources.length; i++)
      if (canonicalLineSources[i] >= 0) canonicalLineSources[i]: i,
  };
  final List<int> _canonicalLinePrefix;

  /// The resource path of this page (`page_N.html`, 1-based — the
  /// parser's historical convention).
  String get resourcePath => 'page_${pageIndex + 1}.html';

  /// The source line index the word at [index] sits in — the word's
  /// provenance — or null when no source line's band contains it.
  int? wordSourceLine(final int index) {
    if (index < 0 || index >= words.length) {
      throw RangeError.index(index, words);
    }

    return _wordLineIndexes[index];
  }

  /// The word at [index]'s exact code-unit range inside its source
  /// line's text, or null when the word has no source line.
  (int, int)? wordSourceRange(final int index) {
    if (index < 0 || index >= words.length) {
      throw RangeError.index(index, words);
    }

    return _wordRanges[index];
  }

  /// Maps a source-space range into a canonical text: the structure's
  /// own, or [targetText] (another profile's canonical form of the
  /// same page). Returns exactly one outcome.
  PdfPositionMapping mapSourceRange(final PdfSourceRange range, {final String? targetText}) {
    if (range.pageIndex != pageIndex) {
      return const PdfPositionMissing(reason: PdfPositionMissingReason.pageMismatch);
    }
    if (canonicalText.isEmpty) {
      return const PdfPositionUnsupported(reason: PdfPositionUnsupportedReason.noCanonicalProfile);
    }
    if (range.lineIndex >= sourceLines.length) {
      return const PdfPositionMissing(reason: PdfPositionMissingReason.lineIndexOutOfRange);
    }
    final line = sourceLines[range.lineIndex];
    final expected = range.expectedLineText;
    if (expected != null && expected != line.text) {
      return const PdfPositionMissing(reason: PdfPositionMissingReason.textMismatch);
    }
    if (range.end > line.text.length) {
      return const PdfPositionMissing(reason: PdfPositionMissingReason.boundsOutOfRange);
    }

    final target = targetText ?? canonicalText;
    if (identical(target, canonicalText) || target == canonicalText) {
      final canonicalIndex = _sourceToCanonical[range.lineIndex];
      if (canonicalIndex == null) {
        return const PdfPositionMissing(reason: PdfPositionMissingReason.lineDroppedByReflow);
      }

      return PdfPositionMapped(
        position: PdfMappedPosition(
          offset: _canonicalLinePrefix[canonicalIndex] + range.start,
          length: range.length,
        ),
      );
    }

    return _mapAgainstForeignTarget(line, range, target);
  }

  /// Maps into a text this structure did not produce: provenance is
  /// unavailable, so the line's own text aligns by content. A single
  /// occurrence maps; repeated text is a real ambiguity with
  /// candidates; absence is missing.
  PdfPositionMapping _mapAgainstForeignTarget(
    final PdfTextLine line,
    final PdfSourceRange range,
    final String target,
  ) {
    final candidates = <PdfMappedPosition>[];
    var searchFrom = 0;
    while (true) {
      final found = target.indexOf(line.text, searchFrom);
      if (found < 0) break;
      candidates.add(PdfMappedPosition(offset: found + range.start, length: range.length));
      searchFrom = found + 1;
    }
    if (candidates.isEmpty) {
      if (line.text.isEmpty) {
        return const PdfPositionMissing(reason: PdfPositionMissingReason.targetTextMismatch);
      }

      return const PdfPositionMissing(reason: PdfPositionMissingReason.targetTextMismatch);
    }
    if (candidates.length == 1) return PdfPositionMapped(position: candidates.single);

    return PdfPositionAmbiguous(candidates: candidates);
  }

  /// The source-space snapshot of the page: its raw line list joined
  /// with `\n`, under the stable source-lines profile.
  CanonicalTextSnapshot sourceSnapshot({required final PublicationRevision identity}) {
    return CanonicalTextSnapshot(
      identity: identity,
      occurrence: _occurrence(),
      profile: _sourceProfile(),
      text: _sourceText(),
    );
  }

  /// The canonical snapshot of the page under the structure's own
  /// profile: the text a reading mode serves for this page.
  CanonicalTextSnapshot canonicalSnapshot({required final PublicationRevision identity}) {
    return CanonicalTextSnapshot(
      identity: identity,
      occurrence: _occurrence(),
      profile: canonicalProfile,
      text: canonicalText,
    );
  }

  /// Whether a source range re-mints to the same anchor after a
  /// reopening: the line exists and carries the same text.
  bool verifiesAnchor(final PdfSourceRange range) {
    if (range.pageIndex != pageIndex || range.lineIndex >= sourceLines.length) {
      return false;
    }
    final expected = range.expectedLineText;

    return expected == null || expected == sourceLines[range.lineIndex].text;
  }

  String _sourceText() => sourceLines.map((final line) => line.text).join('\n');

  SectionOccurrence _occurrence() {
    return SectionOccurrence(
      sectionIndex: pageIndex,
      resourcePath: resourcePath,
      readingOrderRevision: RevisionDigest.readingOrderRevision(readingOrderPaths),
    );
  }

  /// The visible geometry of a parsed page: crop-box dimensions in
  /// the rotated top-left page space, plus the affine back to user
  /// space.
  static PdfPageGeometry geometryOfPage(final PdfPage page) {
    final box = page.cropBox ?? page.mediaBox;
    final boxWidth = box[2] - box[0];
    final boxHeight = box[3] - box[1];
    // A 90/270 rotation swaps the visible dimensions.
    final swapped = page.rotate % 180 == 90;

    return PdfPageGeometry(
      width: swapped ? boxHeight : boxWidth,
      height: swapped ? boxWidth : boxHeight,
      rotation: page.rotate,
      cropBox: box,
    );
  }

  static TextProfile? _sourceProfileMemo;

  static TextProfile _sourceProfile() {
    return _sourceProfileMemo ??= TextProfile.of(
      algorithm: 'pdf.source-lines',
      options: const <String, String>{},
      planRevision: RevisionDigest.textRevision(_sourceExtractionRevisionSeed),
    );
  }

  static PdfBlockRole _roleOf(
    final PdfSegmentBlock block, {
    required final double headerSkip,
    required final double footerSkip,
  }) {
    final middle = block.y + block.height / 2;
    if (headerSkip > 0 && middle < headerSkip) return PdfBlockRole.header;
    if (footerSkip > 0 && middle > footerSkip) return PdfBlockRole.footer;

    return PdfBlockRole.content;
  }

  /// The canonical lines are the source lines minus the reflow's cuts
  /// and reorderings — exact geometry+text tuples, so alignment is
  /// exact: one match per canonical line, leftovers are the dropped
  /// lines.
  static List<int> _alignCanonicalToSource(
    final List<PdfTextLine> canonicalLines,
    final List<PdfTextLine> sourceLines,
  ) {
    final byKey = <String, List<int>>{};
    for (var i = 0; i < sourceLines.length; i++) {
      byKey.putIfAbsent(_sourceLineKey(sourceLines[i]), () => <int>[]).add(i);
    }

    final sources = <int>[];
    for (final line in canonicalLines) {
      final candidates = byKey[_sourceLineKey(line)];
      if (candidates == null || candidates.isEmpty) {
        sources.add(-1);
        continue;
      }
      sources.add(candidates.removeLast());
    }

    return sources;
  }

  static String _sourceLineKey(final PdfTextLine line) {
    return '${line.text}|${line.x}|${line.y}|${line.width}|${line.height}'
        '|${line.fontSize}|${line.rotated}';
  }

  /// Associates each word with the source line whose band contains it
  /// and the word's exact code-unit range inside that line's text.
  /// Geometry picks the line; a whitespace-tolerant scan finds the
  /// offset — the word's own text came from the same extraction, so
  /// the match is exact up to the whitespace the word grouped.
  static void _associateWordsToSourceLines(
    final List<PdfWord> words,
    final List<PdfTextLine> sourceLines,
    final List<int?> wordLineIndexes,
    final List<(int, int)?> wordRanges,
  ) {
    if (sourceLines.isEmpty) return;

    final buckets = <int, List<int>>{};
    for (var i = 0; i < sourceLines.length; i++) {
      final line = sourceLines[i];
      final from = (line.y / 4).floor();
      final to = (line.bottom / 4).floor();
      for (var bucket = from; bucket <= to; bucket++) {
        buckets.putIfAbsent(bucket, () => <int>[]).add(i);
      }
    }

    for (var w = 0; w < words.length; w++) {
      final word = words[w];
      final center = word.y + word.height / 2;
      final bucket = (center / 4).floor();
      int? best;
      var bestDistance = double.infinity;
      for (var candidate = bucket - 1; candidate <= bucket + 1; candidate++) {
        for (final i in buckets[candidate] ?? const <int>[]) {
          final line = sourceLines[i];
          if (word.x + word.width / 2 < line.x - 2 ||
              word.x + word.width / 2 > line.x + line.width + 2) {
            continue;
          }
          final distance = (line.y + line.height / 2 - center).abs();
          if (distance < bestDistance) {
            bestDistance = distance;
            best = i;
          }
        }
      }
      if (best == null) continue;
      final line = sourceLines[best];
      if (word.y + word.height / 2 < line.y - line.height ||
          word.y + word.height / 2 > line.bottom + line.height) {
        continue;
      }
      final range = _locateInLineText(word.text, line.text);
      wordLineIndexes[w] = best;
      wordRanges[w] = range;
    }
  }

  /// Whitespace-tolerant search for [needle] in [haystack]: any run of
  /// whitespace in the needle matches any run in the haystack. Returns
  /// the `(start, end)` in the haystack, or null.
  static (int, int)? _locateInLineText(final String needle, final String haystack) {
    if (needle.isEmpty) return null;

    bool isSpace(final String s, final int i) {
      final unit = s.codeUnitAt(i);

      return unit == 0x20 || (unit >= 0x09 && unit <= 0x0D);
    }

    var start = 0;
    while (true) {
      var h = start;
      var n = 0;
      while (n < needle.length && h < haystack.length) {
        if (isSpace(needle, n) && isSpace(haystack, h)) {
          while (n < needle.length && isSpace(needle, n)) {
            n++;
          }
          while (h < haystack.length && isSpace(haystack, h)) {
            h++;
          }
          continue;
        }
        if (needle.codeUnitAt(n) != haystack.codeUnitAt(h)) break;
        n++;
        h++;
      }
      if (n == needle.length) return (start, h);
      if (h == haystack.length) return null;
      final next = haystack.indexOf(needle[0], start + 1);
      if (next < 0) return null;
      start = next;
    }
  }

  static List<int> _prefixOf(final String text) {
    // Prefix offsets of the `\n`-split lines of [text]; the caller
    // passes the canonical text, so this recomputes the line starts.
    final prefix = <int>[];
    var offset = 0;
    for (final line in text.split('\n')) {
      prefix.add(offset);
      offset += line.length + 1;
    }

    return prefix;
  }
}
