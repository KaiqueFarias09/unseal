import 'package:e_livre/src/features/cfi/epub_cfi.dart';
import 'package:e_livre/src/features/epub/entities/entities.dart';
import 'package:xml/xml.dart';

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

  /// Character offset inside the addressed text node, when the CFI
  /// targets one.
  final int? charOffset;

  /// The addressed text node's content, excerpted around
  /// [charOffset].
  final String? textExcerpt;

  /// Tag names walked while resolving the intra-document steps.
  final List<String> elementTrail;

  @override
  String toString() =>
      'EpubCfiLocation(content: $contentIndex, path: $contentPath, '
      'offset: $charOffset, trail: $elementTrail)';
}

/// Resolves CFIs to content files and DOM positions, and builds CFIs
/// from positions inside an [EpubBook].
extension EpubCfiResolver on EpubBook {
  /// Resolves [cfi] against this book, or `null` when the CFI points
  /// outside the book (unknown spine item, step past the DOM).
  EpubCfiLocation? resolveCfi(final EpubCfi cfi) {
    final segments = cfi.start.segments;
    if (segments.isEmpty) return null;

    // Canonical CFIs carry two segments: the package/spine steps and
    // the document steps. A single segment is treated as a spine
    // step alone.
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

    final trail = <String>[];
    if (documentSegment == null) {
      return EpubCfiLocation(
        contentIndex: contentIndex,
        contentPath: section.name,
        charOffset: spineStep.charOffset,
        elementTrail: trail,
      );
    }

    final root = _parseDocument(file.content);
    if (root == null) return null;

    XmlElement node = root;
    for (var i = 0; i < documentSegment.steps.length; i++) {
      final step = documentSegment.steps[i];
      final isLast = i == documentSegment.steps.length - 1;
      if (step.index.isEven) {
        final elements = node.children.whereType<XmlElement>().toList();
        final index = step.index ~/ 2 - 1;
        if (index < 0 || index >= elements.length) return null;
        node = elements[index];
        trail.add(node.name.local);
        if (isLast) {
          return EpubCfiLocation(
            contentIndex: contentIndex,
            contentPath: section.name,
            elementTrail: trail,
            textExcerpt: _excerpt(node.innerText, 0),
          );
        }
      } else {
        final texts = node.children
            .where((final child) => child is XmlText || child is XmlCDATA)
            .toList();
        final ordinal = (step.index + 1) ~/ 2 - 1;
        if (ordinal < 0 || ordinal >= texts.length) return null;
        final text = texts[ordinal].value ?? '';
        final offset = (step.charOffset ?? 0).clamp(0, text.length);
        return EpubCfiLocation(
          contentIndex: contentIndex,
          contentPath: section.name,
          charOffset: offset,
          textExcerpt: _excerpt(text, offset),
          elementTrail: trail,
        );
      }
    }

    return EpubCfiLocation(
      contentIndex: contentIndex,
      contentPath: section.name,
      elementTrail: trail,
    );
  }

  /// Builds a range-less CFI pointing at [offsetInText] of the raw
  /// concatenated text of the content section at [contentIndex] in
  /// the reading order.
  ///
  /// The offset counts every character of every text node of the
  /// document (whitespace included), in document order.
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

    final root = _parseDocument(file.content);
    if (root == null) throw StateError('content section ${section.name} is not valid XML');

    // Walk the document text in order to find the node that holds the
    // offset, keeping each node's path from the root.
    final parents = <XmlElement>[];
    XmlNode? target;
    var targetOffset = 0;
    var consumed = 0;

    void visit(final XmlNode node) {
      if (target != null) return;
      if (node is XmlText || node is XmlCDATA) {
        final length = (node.value ?? '').length;
        if (offsetInText < consumed + length) {
          target = node;
          targetOffset = offsetInText - consumed;
        }
        consumed += length;
        return;
      }
      if (node is XmlElement) {
        parents.add(node);
        for (final child in node.children) {
          visit(child);
          if (target != null) return;
        }
        parents.removeLast();
      }
    }

    visit(root);
    if (target == null) {
      throw RangeError.value(offsetInText, 'offsetInText', 'past the end of the document');
    }

    final steps = <EpubCfiStep>[];
    for (final parent in parents) {
      if (identical(parent, root)) continue;
      final siblings = parent.parentElement?.children.whereType<XmlElement>().toList() ?? const <XmlElement>[];
      final ordinal = siblings.indexOf(parent) + 1;
      steps.add(EpubCfiStep(index: ordinal * 2));
    }
    // The text node itself: odd step 2k-1 for the k-th character-data
    // child of its parent.
    final owner = target is XmlElement ? target : target!.parent;
    final textSiblings = owner?.children
        .where((final child) => child is XmlText || child is XmlCDATA)
        .toList();
    final textOrdinal = textSiblings?.indexOf(target!) ?? 0;
    steps.add(EpubCfiStep(index: textOrdinal * 2 + 1, charOffset: targetOffset));

    final path = EpubCfiPath(
      segments: [
        EpubCfiSegment(
          steps: [
            const EpubCfiStep(index: 6),
            EpubCfiStep(index: (contentIndex + 1) * 2),
          ],
        ),
        EpubCfiSegment(steps: steps),
      ],
    );
    return EpubCfi(start: path).encode();
  }
}

XmlElement? _parseDocument(final String content) {
  try {
    return XmlDocument.parse(content).rootElement;
  } on XmlException {
    return null;
  }
}

String _excerpt(final String text, final int offset) {
  if (text.isEmpty) return '';
  final from = (offset - 24).clamp(0, text.length);
  final to = (offset + 24).clamp(0, text.length);
  return text.substring(from, to);
}
