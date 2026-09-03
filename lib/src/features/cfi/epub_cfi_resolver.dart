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
    this.textExcerpt,
    this.elementTrail = const <String>[],
  });

  /// Index of the content section inside the book's reading order.
  final int contentIndex;

  /// Path of the content file the CFI points into.
  final String contentPath;

  /// Character offset inside the document text (`documentText`
  /// space), when the CFI targets a text node.
  final int? charOffset;

  /// The addressed text, excerpted around [charOffset].
  final String? textExcerpt;

  /// Tag names walked while resolving the intra-document steps.
  final List<String> elementTrail;

  @override
  String toString() =>
      'EpubCfiLocation(content: $contentIndex, path: $contentPath, '
      'offset: $charOffset, trail: $elementTrail)';
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

    if (documentSegment == null) {
      return EpubCfiLocation(
        contentIndex: contentIndex,
        contentPath: section.name,
        charOffset: spineStep.charOffset,
      );
    }

    final document = EpubCfiDocument.parse(file.content);
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
    final document = EpubCfiDocument.parse(file.content);
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
}

String _excerpt(final String text, final int offset) {
  if (text.isEmpty) return '';
  final from = (offset - 24).clamp(0, text.length);
  final to = (offset + 24).clamp(0, text.length);
  return text.substring(from, to);
}
