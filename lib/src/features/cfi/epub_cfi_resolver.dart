import '../../foundation/entities/file/text_file.dart';
import '../epub/entities/entities.dart';
import 'epub_cfi.dart';
import 'epub_cfi_document.dart';

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

  /// Character offset inside the document-text space, when the CFI targets a text node. For range
  /// CFIs, the first offset of the range.
  final int? charOffset;

  /// Exclusive end offset inside the document text when the CFI is a range (`null` for point CFIs).
  final int? endCharOffset;

  /// The addressed text, excerpted around [charOffset] (spanning [charOffset] up to [endCharOffset]
  /// for ranges).
  final String? textExcerpt;

  /// Tag names walked while resolving the intra-document steps.
  final List<String> elementTrail;

  @override
  String toString() {
    return 'EpubCfiLocation(content: $contentIndex, path: $contentPath, '
        'offset: $charOffset, endOffset: $endCharOffset, trail: $elementTrail)';
  }
}

/// Resolves CFIs to content files and document-text positions, and builds CFIs from positions
/// inside an [EpubBook].
///
/// Offsets live in the `DocumentTextScanner.scan` space of each content file — the same visible
/// `<body>` text used by `BookSearch.search` and reading positions.
extension EpubCfiResolver on EpubBook {
  /// Resolves [cfi] against this book, or `null` when the CFI points outside the book (unknown
  /// spine item, steps past the DOM).
  ///
  /// Range CFIs resolve both boundary subpaths inside the section addressed by the leading path:
  /// [EpubCfiLocation.charOffset] carries the range start and [EpubCfiLocation.endCharOffset] the
  /// exclusive end. The boundary subpaths are relative to the leading path, so a range spanning two
  /// sections cannot be expressed without a spine break inside a boundary — such CFIs resolve to
  /// `null`.
  EpubCfiLocation? resolveCfi(final EpubCfi cfi) {
    final segments = cfi.start.segments;
    if (segments.length != 2) return null;

    final spineSegment = segments.first;
    final documentSegment = segments.last;
    final spineStep = spineSegment.steps.last;
    if (spineStep.isText || spineStep.index == 0) return null;

    final contentIndex = spineStep.index ~/ 2 - 1;
    final section = _sectionDocument(this, contentIndex);
    if (section == null) return null;

    final rangeStart = cfi.rangeStart;
    final rangeEnd = cfi.rangeEnd;
    if (rangeStart != null && rangeEnd != null) {
      if (rangeStart.segments.length > 1 || rangeEnd.segments.length > 1) return null;

      final startOffset = _boundaryOffset(section.document, documentSegment.steps, rangeStart);
      final endOffset = _boundaryOffset(section.document, documentSegment.steps, rangeEnd);
      if (startOffset == null || endOffset == null || endOffset < startOffset) return null;

      return EpubCfiLocation(
        contentIndex: contentIndex,
        contentPath: section.path,
        charOffset: startOffset,
        endCharOffset: endOffset,
        textExcerpt: _excerpt(section.document.text, startOffset, end: endOffset),
        elementTrail: const <String>[],
      );
    }

    final local = EpubCfi(start: EpubCfiPath(segments: [documentSegment]));
    final offset = section.document.offsetForCfi(local);
    if (offset == null) return null;

    return EpubCfiLocation(
      contentIndex: contentIndex,
      contentPath: section.path,
      charOffset: offset,
      textExcerpt: _excerpt(section.document.text, offset),
      elementTrail: const <String>[],
    );
  }

  /// Builds a book-level CFI (`epubcfi(/6/N!…)`) pointing at [offsetInText] of the document text of
  /// the content section at [contentIndex] in the reading order.
  String buildEpubCfi({required final int contentIndex, required final int offsetInText}) {
    final section = _requiredSectionDocument(this, contentIndex);
    if (offsetInText < 0 || offsetInText > section.document.text.length) {
      throw RangeError.range(offsetInText, 0, section.document.text.length, 'offsetInText');
    }

    final local = section.document.cfiForOffset(offsetInText);

    return _bookCfi(contentIndex, local.start.segments.single).encode();
  }

  /// Builds a book-level range CFI (`epubcfi(leading,start,end)`) addressing
  /// `[startOffset, endOffset)` of the document text of the content section at [contentIndex] in
  /// the reading order.
  ///
  /// The leading path carries the spine steps plus the document steps shared by both boundaries;
  /// each boundary subpath continues relative to it and ends in its offset-bearing text step — the
  /// spec range form, so the output round-trips through `EpubCfi.tryParse` and `encode`. Equal
  /// offsets degenerate to the point form of [buildEpubCfi].
  ///
  /// Throws [ArgumentError] when [startOffset] is greater than [endOffset], and [RangeError] when
  /// [contentIndex] does not name a reading order section, the section is not an HTML file, or
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

    final section = _requiredSectionDocument(this, contentIndex);
    if (startOffset < 0 || startOffset > section.document.text.length) {
      throw RangeError.range(startOffset, 0, section.document.text.length, 'startOffset');
    }
    if (endOffset < 0 || endOffset > section.document.text.length) {
      throw RangeError.range(endOffset, 0, section.document.text.length, 'endOffset');
    }

    final startLocal = section.document.cfiForOffset(startOffset);
    final endLocal = section.document.cfiForOffset(endOffset);
    final startSteps = startLocal.start.segments.single.steps;
    final endSteps = endLocal.start.segments.single.steps;

    // The leading path shares every step the two boundaries have in common, except each boundary's
    // own offset-bearing final step.
    var shared = 0;
    final cap = (startSteps.length < endSteps.length ? startSteps.length : endSteps.length) - 1;
    while (shared < cap && _sameStep(startSteps[shared], endSteps[shared])) {
      shared++;
    }

    return EpubCfi(
      start: EpubCfiPath(
        segments: [
          _spineSegment(contentIndex),
          if (shared > 0) EpubCfiSegment(steps: startSteps.take(shared)),
        ],
      ),
      rangeStart: _boundaryPath(startLocal, shared),
      rangeEnd: _boundaryPath(endLocal, shared),
    ).encode();
  }
}

String _excerpt(final String text, final int offset, {final int? end}) {
  if (text.isEmpty) return '';

  final from = (offset - 24).clamp(0, text.length);
  final to = ((end ?? offset) + 24).clamp(0, text.length);

  return text.substring(from, to);
}

/// Document-text offset of a range [boundary], resolved against [baseSteps], the document steps of
/// the leading path it continues.
int? _boundaryOffset(
  final EpubCfiDocument document,
  final List<EpubCfiStep> baseSteps,
  final EpubCfiPath boundary,
) {
  final boundarySteps = boundary.segments.isEmpty
      ? const <EpubCfiStep>[]
      : boundary.segments.single.steps;
  final local = EpubCfi(
    start: EpubCfiPath(
      segments: [
        EpubCfiSegment(steps: [...baseSteps, ...boundarySteps]),
      ],
    ),
  );

  return document.offsetForCfi(local);
}

/// The boundary subpath of the file-local point CFI [local]: its steps after the [shared] steps
/// carried by the leading path, with the point's offset and id assertion on the final step.
EpubCfiPath _boundaryPath(final EpubCfi local, final int shared) {
  final steps = local.start.segments.single.steps;

  return EpubCfiPath(segments: [EpubCfiSegment(steps: steps.skip(shared))]);
}

bool _sameStep(final EpubCfiStep left, final EpubCfiStep right) {
  return left.index == right.index && left.assertion == right.assertion;
}

EpubCfiSegment _spineSegment(final int contentIndex) {
  return EpubCfiSegment(
    steps: [
      EpubCfiStep(index: 6),
      EpubCfiStep(index: (contentIndex + 1) * 2),
    ],
  );
}

EpubCfi _bookCfi(final int contentIndex, final EpubCfiSegment documentSegment) {
  return EpubCfi(start: EpubCfiPath(segments: [_spineSegment(contentIndex), documentSegment]));
}

({String path, EpubCfiDocument document})? _sectionDocument(
  final EpubBook book,
  final int contentIndex,
) {
  if (contentIndex < 0 || contentIndex >= book.readingOrder.length) return null;

  final path = book.readingOrder[contentIndex].name;
  TextFile? file;
  for (final candidate in book.files.html) {
    if (candidate.path == path) {
      file = candidate;
      break;
    }
  }

  if (file == null) return null;

  return (path: path, document: _documentOf(book, file));
}

({String path, EpubCfiDocument document}) _requiredSectionDocument(
  final EpubBook book,
  final int contentIndex,
) {
  if (contentIndex < 0 || contentIndex >= book.readingOrder.length) {
    throw RangeError.range(contentIndex, 0, book.readingOrder.length - 1, 'contentIndex');
  }

  final section = _sectionDocument(book, contentIndex);
  if (section == null) {
    throw StateError('content section ${book.readingOrder[contentIndex].name} is not an HTML file');
  }

  return section;
}

/// Parsed section documents of the books seen so far, keyed by book.
///
/// A Dart extension cannot add fields to [EpubBook] and the foundation entities must not depend on
/// features, so the cache lives here, inside the cfi feature, and hangs off the book through an
/// [Expando]: entries die with their book instance and different book instances never share
/// documents.
///
/// Invalidation is not needed: books are parsed once and immutable afterwards — `TextFile.content`
/// is final and neither `resolveCfi` nor `buildEpubCfi` mutates the parsed tree of an
/// [EpubCfiDocument] — so a document parsed for a (book, section) pair stays correct forever.
final Expando<Map<String, EpubCfiDocument>> _documentCaches =
    Expando<Map<String, EpubCfiDocument>>();

/// The per-book document cache of [book], created on first use.
Map<String, EpubCfiDocument> _documentsOf(final EpubBook book) {
  return _documentCaches[book] ??= <String, EpubCfiDocument>{};
}

/// The parsed document model of [file] for [book], parsing and caching on first access. Section
/// paths are unique inside a book, so the file path identifies the section.
EpubCfiDocument _documentOf(final EpubBook book, final TextFile file) {
  return _documentsOf(book).putIfAbsent(file.path, () => EpubCfiDocument.parse(file.content));
}
