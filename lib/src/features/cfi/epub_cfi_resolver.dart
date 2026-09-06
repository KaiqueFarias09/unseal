import 'package:e_livre/src/features/cfi/epub_cfi.dart';
import 'package:e_livre/src/features/cfi/epub_cfi_document.dart';
import 'package:e_livre/src/features/epub/entities/entities.dart';

/// The result of resolving a CFI against an [EpubBook].
final class EpubCfiLocation {
  /// Creates an [EpubCfiLocation].
  const EpubCfiLocation({
    required this.contentIndex,
    required this.contentPath,
    this.charOffset,
    this.endCharOffset,
    this.textExcerpt,
    this.elementTrail = const <String>[],
  });

  /// Index of the content section inside the book's reading order.
  final int contentIndex;

  /// Path of the content file the CFI points into.
  final String contentPath;

  /// Character offset inside the document text (`documentText`
  /// space), when the CFI targets a text node. For range CFIs, the
  /// first offset of the range.
  final int? charOffset;

  /// Exclusive end offset inside the document text when the CFI is a
  /// range (`null` for point CFIs).
  final int? endCharOffset;

  /// The addressed text, excerpted around [charOffset] (spanning
  /// [charOffset] up to [endCharOffset] for ranges).
  final String? textExcerpt;

  /// Tag names walked while resolving the intra-document steps.
  final List<String> elementTrail;

  @override
  String toString() =>
      'EpubCfiLocation(content: $contentIndex, path: $contentPath, '
      'offset: $charOffset, endOffset: $endCharOffset, trail: $elementTrail)';
}

/// Resolves CFIs to content files and document-text positions, and
/// builds CFIs from positions inside an [EpubBook].
///
/// Offsets live in the `documentText` space of each content file
/// (visible text inside `<body>`, whitespace as-is) — the same space
/// as `BookSearch.search` and reading positions.
extension EpubCfiResolver on EpubBook {
  /// Resolves [cfi] against this book, or `null` when the CFI points
  /// outside the book (unknown spine item, steps past the DOM).
  ///
  /// Range CFIs resolve both boundary subpaths inside the section
  /// addressed by the leading path: [EpubCfiLocation.charOffset]
  /// carries the range start and [EpubCfiLocation.endCharOffset] the
  /// exclusive end. The boundary subpaths are relative to the leading
  /// path, so a range spanning two sections cannot be expressed
  /// without a spine break inside a boundary — such CFIs resolve to
  /// `null`.
  EpubCfiLocation? resolveCfi(final EpubCfi cfi) {
    final segments = cfi.start.segments;
    if (segments.isEmpty) return null;

    // Canonical book CFIs carry two segments: the package/spine steps
    // and the file-local document steps. A single segment is treated
    // as document steps of the first spine item.
    EpubCfiSegment spineSegment;
    EpubCfiSegment? documentSegment;
    if (segments.length >= 2) {
      spineSegment = segments.first;
      documentSegment = segments[1];
    } else {
      spineSegment = segments.first;
    }

    final spineStep = spineSegment.steps.last;
    final contentIndex = spineStep.index ~/ 2 - 1;
    final sections = readingOrder;
    if (contentIndex < 0 || contentIndex >= sections.length) return null;
    final section = sections[contentIndex];

    TextFile? file;
    for (final candidate in files.html) {
      if (candidate.path == section.name) {
        file = candidate;
        break;
      }
    }
    if (file == null) return null;

    final rangeStart = cfi.rangeStart;
    final rangeEnd = cfi.rangeEnd;
    if (rangeStart != null && rangeEnd != null) {
      if (rangeStart.segments.length > 1 || rangeEnd.segments.length > 1) return null;

      final document = _documentOf(this, file);
      final baseSteps = documentSegment == null
          ? const <int>[]
          : <int>[for (final step in documentSegment.steps) step.index];
      final startOffset = _boundaryOffset(document, baseSteps, rangeStart.segments.first);
      final endOffset = _boundaryOffset(document, baseSteps, rangeEnd.segments.first);
      if (startOffset == null || endOffset == null) return null;

      return EpubCfiLocation(
        contentIndex: contentIndex,
        contentPath: section.name,
        charOffset: startOffset,
        endCharOffset: endOffset,
        textExcerpt: _rangeExcerpt(document.text, startOffset, endOffset),
        elementTrail: const <String>[],
      );
    }

    if (documentSegment == null) {
      return EpubCfiLocation(
        contentIndex: contentIndex,
        contentPath: section.name,
        charOffset: spineStep.charOffset,
      );
    }

    final document = _documentOf(this, file);
    final steps = <int>[for (final step in documentSegment.steps) step.index];
    final localOffset = EpubCfi.simple(
      steps: steps,
      charOffset: spineStep.charOffset ?? documentSegment.steps.last.charOffset ?? 0,
    );
    final offset = document.offsetForCfi(localOffset);
    if (offset == null) return null;

    return EpubCfiLocation(
      contentIndex: contentIndex,
      contentPath: section.name,
      charOffset: offset,
      textExcerpt: _excerpt(document.text, offset),
      elementTrail: const <String>[],
    );
  }

  /// Builds a book-level CFI (`epubcfi(/6/N!…)`) pointing at
  /// [offsetInText] of the document text of the content section at
  /// [contentIndex] in the reading order.
  String buildEpubCfi({required final int contentIndex, required final int offsetInText}) {
    final sections = readingOrder;
    if (contentIndex < 0 || contentIndex >= sections.length) {
      throw RangeError.range(contentIndex, 0, sections.length - 1, 'contentIndex');
    }
    final section = sections[contentIndex];

    TextFile? file;
    for (final candidate in files.html) {
      if (candidate.path == section.name) {
        file = candidate;
        break;
      }
    }
    if (file == null) {
      throw StateError('content section ${section.name} is not an HTML file');
    }

    // The file-local steps come from the document model; the spine
    // segment is prepended so the CFI addresses the whole book:
    // /6 is the spine element, /2N the N-th itemref.
    final document = _documentOf(this, file);
    if (offsetInText < 0 || offsetInText > document.text.length) {
      throw RangeError.range(offsetInText, 0, document.text.length, 'offsetInText');
    }
    final local = document.cfiForOffset(offsetInText);
    final spine = EpubCfi.simple(steps: [6, (contentIndex + 1) * 2]);
    final prefixed = EpubCfi(
      start: EpubCfiPath(segments: [...spine.start.segments, ...local.start.segments]),
    );
    return prefixed.encode();
  }

  /// Builds a book-level range CFI (`epubcfi(leading,start,end)`)
  /// addressing `[startOffset, endOffset)` of the document text of the
  /// content section at [contentIndex] in the reading order.
  ///
  /// The leading path carries the spine steps plus the document steps
  /// shared by both boundaries; each boundary subpath continues
  /// relative to it and ends in its offset-bearing text step — the
  /// spec range form, so the output round-trips through
  /// `EpubCfi.tryParse` and `encode`. Equal offsets degenerate to the
  /// point form of [buildEpubCfi].
  ///
  /// Throws [ArgumentError] when [startOffset] is greater than
  /// [endOffset], and [RangeError] when [contentIndex] does not name
  /// a reading order section, the section is not an HTML file, or
  /// either offset falls outside the section's document text.
  String buildEpubCfiRange({
    required final int contentIndex,
    required final int startOffset,
    required final int endOffset,
  }) {
    if (startOffset > endOffset) {
      throw ArgumentError.value(
        endOffset,
        'endOffset',
        'must not be smaller than startOffset ($startOffset)',
      );
    }
    if (startOffset == endOffset) {
      return buildEpubCfi(contentIndex: contentIndex, offsetInText: startOffset);
    }

    final sections = readingOrder;
    if (contentIndex < 0 || contentIndex >= sections.length) {
      throw RangeError.range(contentIndex, 0, sections.length - 1, 'contentIndex');
    }
    final section = sections[contentIndex];

    TextFile? file;
    for (final candidate in files.html) {
      if (candidate.path == section.name) {
        file = candidate;
        break;
      }
    }
    if (file == null) {
      throw StateError('content section ${section.name} is not an HTML file');
    }

    final document = _documentOf(this, file);
    if (startOffset < 0 || startOffset > document.text.length) {
      throw RangeError.range(startOffset, 0, document.text.length, 'startOffset');
    }
    if (endOffset < 0 || endOffset > document.text.length) {
      throw RangeError.range(endOffset, 0, document.text.length, 'endOffset');
    }

    final startLocal = document.cfiForOffset(startOffset);
    final endLocal = document.cfiForOffset(endOffset);
    final startSteps = startLocal.steps;
    final endSteps = endLocal.steps;

    // The leading path shares every step the two boundaries have in
    // common, except each boundary's own offset-bearing final step.
    var shared = 0;
    final cap = (startSteps.length < endSteps.length ? startSteps.length : endSteps.length) - 1;
    while (shared < cap && startSteps[shared] == endSteps[shared]) {
      shared++;
    }

    return EpubCfi(
      start: EpubCfiPath(
        segments: [
          EpubCfiSegment(
            steps: [
              const EpubCfiStep(index: 6),
              EpubCfiStep(index: (contentIndex + 1) * 2),
            ],
          ),
          if (shared > 0)
            EpubCfiSegment(
              steps: [for (var i = 0; i < shared; i++) EpubCfiStep(index: startSteps[i])],
            ),
        ],
      ),
      rangeStart: _boundaryPath(startLocal, shared),
      rangeEnd: _boundaryPath(endLocal, shared),
    ).encode();
  }
}

String _excerpt(final String text, final int offset) {
  if (text.isEmpty) return '';
  final from = (offset - 24).clamp(0, text.length);
  final to = (offset + 24).clamp(0, text.length);
  return text.substring(from, to);
}

/// Document-text offset of a range boundary [segment], resolved
/// against [baseSteps] — the document steps of the leading path the
/// segment continues.
int? _boundaryOffset(
  final EpubCfiDocument document,
  final List<int> baseSteps,
  final EpubCfiSegment segment,
) {
  final local = EpubCfi.simple(
    steps: [...baseSteps, for (final step in segment.steps) step.index],
    charOffset: segment.steps.last.charOffset ?? 0,
  );
  return document.offsetForCfi(local);
}

/// The excerpt of [text] spanning `start..end`, padded on both sides
/// like [_excerpt].
String _rangeExcerpt(final String text, final int start, final int end) {
  if (text.isEmpty) return '';
  final from = (start - 24).clamp(0, text.length);
  final to = (end + 24).clamp(0, text.length);
  return text.substring(from, to);
}

/// The boundary subpath of the file-local point CFI [local]: its
/// steps after the [shared] steps carried by the leading path, with
/// the point's offset and id assertion on the final step.
EpubCfiPath _boundaryPath(final EpubCfi local, final int shared) {
  final steps = local.steps;
  return EpubCfiPath(
    segments: [
      EpubCfiSegment(
        steps: [
          for (var i = shared; i < steps.length; i++)
            EpubCfiStep(
              index: steps[i],
              charOffset: i == steps.length - 1 ? local.charOffset : null,
              assertion: i == steps.length - 1 ? local.idAssertion : null,
            ),
        ],
      ),
    ],
  );
}

/// Parsed section documents of the books seen so far, keyed by book.
///
/// A Dart extension cannot add fields to [EpubBook] and the
/// foundation entities must not depend on features, so the cache
/// lives here, inside the cfi feature, and hangs off the book
/// through an [Expando]: entries die with their book instance and
/// different book instances never share documents.
///
/// Invalidation is not needed: books are parsed once and immutable
/// afterwards — `TextFile.content` is final and neither
/// `resolveCfi` nor `buildEpubCfi` mutates the parsed tree of an
/// [EpubCfiDocument] — so a document parsed for a (book, section)
/// pair stays correct forever.
final Expando<Map<String, EpubCfiDocument>> _documentCaches =
    Expando<Map<String, EpubCfiDocument>>();

/// The per-book document cache of [book], created on first use.
Map<String, EpubCfiDocument> _documentsOf(final EpubBook book) =>
    _documentCaches[book] ??= <String, EpubCfiDocument>{};

/// The parsed document model of [file] for [book], parsing and
/// caching on first access. Section paths are unique inside a book,
/// so the file path identifies the section.
EpubCfiDocument _documentOf(final EpubBook book, final TextFile file) =>
    _documentsOf(book).putIfAbsent(file.path, () => EpubCfiDocument.parse(file.content));
