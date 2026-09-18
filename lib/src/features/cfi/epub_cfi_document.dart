import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import '../../foundation/text/canonical_document_text.dart';
import 'epub_cfi.dart';

/// Position/lookup over the parsed tree of one XHTML file. Text offsets are the concatenation of
/// text nodes inside `<body>` (skipping `script`/`style`), i.e. the same space as
/// [DocumentTextScanner.scan] and the viewer's JS TreeWalker.
class EpubCfiDocument {
  EpubCfiDocument._(this._root, this._body, this._textNodes);

  /// Entities XML resolves natively (decoded into text nodes exactly like [decodeEntity] would);
  /// everything else is pre-decoded.
  static const _xmlPredefinedEntities = <String>{'lt', 'gt', 'amp', 'quot', 'apos'};

  static final RegExp _numericEntityPattern = RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+);');

  /// Parses [xhtml] and indexes its text nodes. Named HTML entities that XML cannot resolve are
  /// decoded first (same entity table as [DocumentTextScanner.scan]); the five XML predefined ones
  /// stay escaped so the parser decodes them itself — unescaping `&lt;`/`&amp;` here would inject
  /// raw `<`/`&` into the parser's view and turn escaped text (a literal `&lt;http://…&gt;`
  /// citation, say) into bogus markup.
  ///
  /// Real publisher content is often tag soup (stray `&`, bare `<`, unclosed void elements,
  /// mismatched close tags) that strict XML rejects. Those sections fall back to HTML5 parsing; the
  /// repaired tree is converted to the XML node model used by the CFI queries.
  factory EpubCfiDocument.parse(final String xhtml) {
    var source = xhtml;
    source = source.replaceAllMapped(RegExp(r'&([a-zA-Z][a-zA-Z0-9]{1,31});'), (final match) {
      if (_xmlPredefinedEntities.contains(match.group(1)!)) {
        return match.group(0)!;
      }

      return decodeEntity(match.group(1)!) ?? match.group(0)!;
    });
    // Numeric C1 refs: [DocumentTextScanner.scan] pins them to U+FFFD, but strict XML would decode
    // them to the raw control and the HTML5 fallback to the Windows-1252 glyph — substitute the
    // pinned character so every path agrees.
    source = source.replaceAllMapped(_numericEntityPattern, (final match) {
      final decoded = decodeEntity(match.group(1)!);

      return decoded == '\uFFFD' ? '\uFFFD' : match.group(0)!;
    });
    try {
      final doc = XmlDocument.parse(source);
      final body = doc.findAllElements('body').firstOrNull;
      if (body == null || doc.rootElement.name.local.toLowerCase() != 'html') {
        return EpubCfiDocument._html5Fallback(source);
      }

      return EpubCfiDocument._(doc.rootElement, body, _indexTextNodes(body));
    } on XmlException {
      return EpubCfiDocument._html5Fallback(source);
    }
  }

  /// HTML5 fallback for tag-soup content documents.
  ///
  /// Every `&` still in [source] is either one of the five XML predefined entities (kept for the
  /// tokenizer to decode into text, matching [DocumentTextScanner.scan]) or an unknown/bare form
  /// [DocumentTextScanner.scan] keeps literal — re-escape those so the HTML5 tokenizer keeps them
  /// literal too instead of decoding half the HTML4 entity table. Stray `<` needs no repair: the
  /// tokenizer emits it as text, and void elements and mismatched close tags follow the spec's tree
  /// construction, matching browser-style content parsing.
  factory EpubCfiDocument._html5Fallback(final String source) {
    final repaired = source.replaceAllMapped(
      RegExp(r'&(?!(?:lt|gt|amp|quot|apos);)'),
      (final _) => '&amp;',
    );
    final document = html.parse(repaired);
    final root = _convertElement(document.documentElement);
    final body = root.findAllElements('body').firstOrNull ?? XmlElement(XmlName('body'));

    return EpubCfiDocument._(root, body, _indexTextNodes(body));
  }

  /// Converts an HTML DOM subtree into the XML node model.
  static XmlElement _convertElement(final dom.Element? element) {
    if (element == null) return XmlElement(XmlName('body'));

    return XmlElement(XmlName(element.localName ?? ''), [
      for (final entry in element.attributes.entries)
        XmlAttribute(XmlName(entry.key.toString()), entry.value.toString()),
    ], element.nodes.map(_convertNode).nonNulls);
  }

  static XmlNode? _convertNode(final dom.Node node) {
    if (node is dom.Element) return _convertElement(node);
    if (node is dom.Text) return XmlText(node.data);
    // Comments and the rest are ignored by EPUB CFI child indexing.
    return null;
  }

  static List<XmlNode> _indexTextNodes(final XmlElement body) {
    final textNodes = <XmlNode>[];
    _appendTextNodes(body, textNodes);

    return textNodes;
  }

  static void _appendTextNodes(final XmlNode node, final List<XmlNode> textNodes) {
    for (final child in node.children) {
      if (_isCharacterData(child)) {
        if (_textValue(child).isNotEmpty) textNodes.add(child);
      } else if (child is XmlElement) {
        final name = child.name.local.toLowerCase();
        if (name == 'script' || name == 'style') {
          continue;
        }
        _appendTextNodes(child, textNodes);
      }
    }
  }

  final XmlElement _root;
  final XmlElement _body;
  final List<XmlNode> _textNodes;

  /// The concatenated document text (the offset space).
  ///
  /// Computed once on first access: the XML tree is parsed once and never mutated afterwards, so
  /// the join cannot change.
  late final String text = _joinTextNodes();

  String _joinTextNodes() {
    final buffer = StringBuffer();
    for (final textNode in _textNodes) {
      buffer.write(_textValue(textNode));
    }

    return buffer.toString();
  }

  /// Offset of the first occurrence of [needle] in the text space.
  int? indexOfText(final String needle) {
    final at = text.indexOf(needle);

    return at < 0 ? null : at;
  }

  /// Character offset of [node] in the document text space.
  int offsetOf(final XmlNode node) {
    var consumed = 0;
    for (final textNode in _textNodes) {
      if (identical(textNode, node)) return consumed;

      consumed += _textValue(textNode).length;
    }

    final elementOffset = node is XmlElement ? _offsetAtStart(node) : null;
    if (elementOffset != null) return elementOffset;

    throw ArgumentError.value(node, 'node', 'is not part of the document text tree');
  }

  XmlNode? _textNodeAt(final int offset) {
    var consumed = 0;
    for (final textNode in _textNodes) {
      final len = _textValue(textNode).length;
      if (consumed + len > offset) return textNode;

      consumed += len;
    }

    return _textNodes.isEmpty ? null : _textNodes.last;
  }

  /// Walks from [node] to the XHTML root, assigning even steps to element siblings and odd steps to
  /// the character-data chunks before, between, and after them, as required by EPUB CFI.
  List<EpubCfiStep> _stepsFor(final XmlNode node) {
    final steps = <EpubCfiStep>[];
    XmlNode current = node;
    while (!identical(current, _root)) {
      final parent = current.parent;
      if (parent == null || parent is XmlDocument) break;

      final step = _stepForChild(parent, current);
      if (step == null) break;

      steps.insert(0, step);
      current = parent;
    }

    return steps;
  }

  EpubCfiStep? _stepForChild(final XmlNode parent, final XmlNode target) {
    var elementsBefore = 0;
    for (final child in parent.children) {
      if (identical(child, target)) {
        if (target is XmlElement) {
          return EpubCfiStep(index: (elementsBefore + 1) * 2, assertion: _idOf(target));
        }
        if (_isCharacterData(target)) return EpubCfiStep(index: elementsBefore * 2 + 1);

        return null;
      }

      if (child is XmlElement) {
        elementsBefore++;
      }
    }

    return null;
  }

  static String? _idOf(final XmlElement element) {
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == 'id') return attribute.value;
    }

    return null;
  }

  /// CFI of the position at [offset]. Element ID assertions are attached to the corresponding even
  /// path steps.
  EpubCfi cfiForOffset(final int offset) {
    if (offset < 0 || offset > text.length) {
      throw RangeError.range(offset, 0, text.length, 'offset');
    }

    final node = _textNodeAt(offset);
    if (node == null) {
      return EpubCfi(
        start: EpubCfiPath(segments: [EpubCfiSegment(steps: _stepsFor(_body))]),
      );
    }

    final steps = _stepsFor(node);
    final chunkOffset = offsetOf(node) - _offsetWithinChunk(node);
    final last = steps.removeLast();
    steps.add(
      EpubCfiStep(index: last.index, charOffset: offset - chunkOffset, assertion: last.assertion),
    );

    return EpubCfi(
      start: EpubCfiPath(segments: [EpubCfiSegment(steps: steps)]),
    );
  }

  /// Character offset of a parsed [cfi] (the decode path): resolves the path against the tree; a
  /// final element step addresses the start of its first text node.
  int? offsetForCfi(final EpubCfi cfi) {
    if (cfi.isRange || cfi.start.segments.length != 1) return null;

    final steps = cfi.start.segments.single.steps;
    XmlNode current = _root;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final isLast = i == steps.length - 1;
      if (step.isText) {
        if (!isLast) return null;

        return _offsetForCharacterData(current, step);
      }

      final element = _elementForStep(current, step);
      if (element == null) {
        if (isLast && _isVirtualElementStep(current, step.index)) {
          return step.index == 0 ? _offsetAtStart(current) : _offsetAtEnd(current);
        }

        return null;
      }

      current = element;
    }

    return _offsetAtStart(current);
  }

  int _offsetWithinChunk(final XmlNode node) {
    var offset = 0;
    for (final sibling in node.parent!.children) {
      if (identical(sibling, node)) return offset;

      if (sibling is XmlElement) {
        offset = 0;
      } else if (_isCharacterData(sibling)) {
        offset += _textValue(sibling).length;
      }
    }
    throw StateError('indexed text node is detached from its parent');
  }

  int? _offsetForCharacterData(final XmlNode parent, final EpubCfiStep step) {
    final slot = (step.index - 1) ~/ 2;
    var elementCount = 0;
    final nodes = <XmlNode>[];
    for (final child in parent.children) {
      if (child is XmlElement) {
        elementCount++;
      } else if (_isCharacterData(child) && elementCount == slot) {
        nodes.add(child);
      }
    }

    final charOffset = step.charOffset ?? 0;
    final chunkLength = nodes.fold<int>(
      0,
      (final sum, final node) => sum + _textValue(node).length,
    );
    if (charOffset > chunkLength) return null;
    if (nodes.isEmpty) return _offsetOfEmptyChunk(parent, slot);

    final firstIndexedNode = nodes
        .where((final candidate) => _textNodes.any((final node) => identical(node, candidate)))
        .firstOrNull;
    if (firstIndexedNode == null) return null;

    return offsetOf(firstIndexedNode) + charOffset;
  }

  XmlElement? _elementForStep(final XmlNode parent, final EpubCfiStep step) {
    final index = step.index ~/ 2;
    if (index < 1) return null;

    final elements = parent.children.whereType<XmlElement>().toList();
    final XmlElement? target = index <= elements.length ? elements[index - 1] : null;
    final assertion = step.assertion;
    if (assertion == null || (target != null && _idOf(target) == assertion)) return target;

    for (final element in elements) {
      if (_idOf(element) == assertion) return element;
    }

    return null;
  }

  bool _isVirtualElementStep(final XmlNode parent, final int step) {
    final lastElementStep = parent.children.whereType<XmlElement>().length * 2;

    return step == 0 || step == lastElementStep + 2;
  }

  int? _offsetOfEmptyChunk(final XmlNode parent, final int slot) {
    final elements = parent.children.whereType<XmlElement>().toList();
    if (slot < 0 || slot > elements.length) return null;
    if (slot == 0) return _offsetAtStart(parent);

    return _offsetAtEnd(elements[slot - 1]);
  }

  int? _offsetAtStart(final XmlNode target) {
    if (identical(target, _body)) return 0;

    return _TextOffsetFinder(target: target, textNodes: _textNodes).find(_root);
  }

  int? _offsetAtEnd(final XmlNode target) {
    final start = _offsetAtStart(target);
    if (start == null) return null;

    return start + _textLength(target);
  }

  int _textLength(final XmlNode node) {
    var length = 0;
    for (final textNode in _textNodes) {
      XmlNode? current = textNode;
      while (current != null) {
        if (identical(current, node)) {
          length += _textValue(textNode).length;
          break;
        }

        current = current.parent;
      }
    }

    return length;
  }

  static bool _isCharacterData(final XmlNode node) => node is XmlText || node is XmlCDATA;

  static String _textValue(final XmlNode node) => node.value ?? '';
}

final class _TextOffsetFinder {
  _TextOffsetFinder({required this.target, required this.textNodes});

  final XmlNode target;
  final List<XmlNode> textNodes;
  var _consumed = 0;
  int? _result;

  int? find(final XmlNode root) {
    _visit(root);

    return _result;
  }

  void _visit(final XmlNode node) {
    if (_result != null) {
      return;
    }
    if (identical(node, target)) {
      _result = _consumed;
    } else if (_isCharacterData(node)) {
      _consumed += _isIndexed(node) ? _textValue(node).length : 0;
    } else if (node is XmlElement && !_isExcludedElement(node)) {
      for (final child in node.children) {
        _visit(child);
      }
    }
  }

  bool _isIndexed(final XmlNode node) {
    return textNodes.any((final textNode) => identical(textNode, node));
  }

  static bool _isCharacterData(final XmlNode node) => node is XmlText || node is XmlCDATA;

  static String _textValue(final XmlNode node) => node.value ?? '';

  static bool _isExcludedElement(final XmlElement element) {
    final name = element.name.local.toLowerCase();

    return name == 'script' || name == 'style';
  }
}
