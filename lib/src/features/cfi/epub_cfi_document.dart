import 'dart:math' as math;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import '../../foundation/text/canonical_document_text.dart';
import 'epub_cfi.dart';

/// Position/lookup over the parsed tree of one XHTML file. Text
/// offsets are the concatenation of text nodes inside `<body>`
/// (skipping `script`/`style`), i.e. the same space as
/// [documentText] and the viewer's JS TreeWalker.
class EpubCfiDocument {
  EpubCfiDocument._(this._body, this._textNodes);

  /// Entities XML resolves natively (decoded into text nodes exactly
  /// like [decodeEntity] would); everything else is pre-decoded.
  static const Set<String> _xmlPredefinedEntities = <String>{'lt', 'gt', 'amp', 'quot', 'apos'};

  static final RegExp _numericEntityPattern = RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+);');

  /// Parses [xhtml] and indexes its text nodes. Named HTML entities
  /// that XML cannot resolve are decoded first (same entity table as
  /// [documentText]); the five XML predefined ones stay escaped so the
  /// parser decodes them itself — unescaping `&lt;`/`&amp;` here would
  /// inject raw `<`/`&` into the parser's view and turn escaped text
  /// (a literal `&lt;http://…&gt;` citation, say) into bogus markup.
  ///
  /// Real publisher content is often tag soup (stray `&`, bare `<`,
  /// unclosed void elements, mismatched close tags) that strict XML
  /// rejects. Those sections fall back to an HTML5 parse — the same
  /// policy as Calibre
  /// (`calibre/ebooks/oeb/parse_utils.py html5_parse`: content
  /// documents go through `html5_parser`, never strict XML) — and the
  /// repaired tree is converted to the XML node model the CFI queries
  /// already speak.
  factory EpubCfiDocument.parse(final String xhtml) {
    var source = xhtml;
    source = source.replaceAllMapped(
      RegExp(r'&([a-zA-Z][a-zA-Z0-9]{1,31});'),
      (final match) => _xmlPredefinedEntities.contains(match.group(1)!)
          ? match.group(0)!
          : (decodeEntity(match.group(1)!) ?? match.group(0)!),
    );
    // Numeric C1 refs: [documentText] pins them to U+FFFD, but strict
    // XML would decode them to the raw control and the HTML5 fallback
    // to the Windows-1252 glyph — substitute the pinned character so
    // every path agrees.
    source = source.replaceAllMapped(_numericEntityPattern, (final match) {
      final decoded = decodeEntity(match.group(1)!);
      return decoded == '\uFFFD' ? '\uFFFD' : match.group(0)!;
    });
    try {
      final doc = XmlDocument.parse(source);
      final body = doc.findAllElements('body').first;
      return EpubCfiDocument._(body, _indexTextNodes(body));
    } on XmlException {
      return EpubCfiDocument._html5Fallback(source);
    }
  }

  /// HTML5 fallback for tag-soup content documents.
  ///
  /// Every `&` still in [source] is either one of the five XML
  /// predefined entities (kept for the tokenizer to decode into text,
  /// matching [documentText]) or an unknown/bare form [documentText]
  /// keeps literal — re-escape those so the HTML5 tokenizer keeps them
  /// literal too instead of decoding half the HTML4 entity table.
  /// Stray `<` needs no repair: the tokenizer emits it as text, and
  /// void elements and mismatched close tags follow the spec's tree
  /// construction, which is exactly what a browser (and Calibre's
  /// viewer) would see.
  factory EpubCfiDocument._html5Fallback(final String source) {
    final repaired = source.replaceAllMapped(
      RegExp(r'&(?!(?:lt|gt|amp|quot|apos);)'),
      (final _) => '&amp;',
    );
    final document = html.parse(repaired);
    final body = _convertElement(document.body);
    return EpubCfiDocument._(body, _indexTextNodes(body));
  }

  /// Converts an HTML DOM subtree into the XML node model.
  static XmlElement _convertElement(final dom.Element? element) {
    if (element == null) {
      return XmlElement(XmlName('body'));
    }
    return XmlElement(
      XmlName(element.localName ?? ''),
      [
        for (final entry in element.attributes.entries)
          XmlAttribute(XmlName(entry.key.toString()), entry.value.toString()),
      ],
      [for (final child in element.nodes) _convertNode(child)],
    );
  }

  static XmlNode _convertNode(final dom.Node node) {
    if (node is dom.Element) {
      return _convertElement(node);
    }
    if (node is dom.Text) {
      return XmlText(node.data);
    }
    // Comments and the rest contribute no text on either side.
    return XmlText('');
  }

  static List<XmlNode> _indexTextNodes(final XmlElement body) {
    final textNodes = <XmlNode>[];
    void walk(final XmlNode node) {
      for (final child in node.children) {
        if (child is XmlText) {
          if (child.value.isNotEmpty) {
            textNodes.add(child);
          }
        } else if (child is XmlElement) {
          final name = child.name.local.toLowerCase();
          if (name == 'script' || name == 'style') {
            continue;
          }
          walk(child);
        }
      }
    }

    walk(body);
    return textNodes;
  }

  final XmlElement _body;
  final List<XmlNode> _textNodes;

  /// The concatenated document text (the offset space).
  ///
  /// Computed once on first access: the XML tree is parsed once and
  /// never mutated afterwards, so the join cannot change.
  late final String text = _joinTextNodes();

  String _joinTextNodes() {
    final buffer = StringBuffer();
    for (final textNode in _textNodes) {
      buffer.write((textNode as XmlText).value);
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
    for (final text in _textNodes) {
      if (identical(text, node)) {
        return consumed;
      }
      consumed += (text as XmlText).value.length;
    }
    return consumed;
  }

  XmlNode? _textNodeAt(final int offset) {
    var consumed = 0;
    for (final text in _textNodes) {
      final len = (text as XmlText).value.length;
      if (consumed + len > offset) {
        return text;
      }
      consumed += len;
    }
    return _textNodes.isEmpty ? null : _textNodes.last;
  }

  /// Parity: calibre cfi.pyj `encode` — walk up from [node] to the
  /// body collecting EPUB steps (element child i -> 2i, text child i
  /// -> 2i-1), skipping highlight wrapper spans just like Calibre
  /// skips `calibreRangeWrapper` spans. The id assertion is taken
  /// from the final element when it carries an `id` attribute.
  List<int> _stepsFor(final XmlNode node) {
    final steps = <int>[];
    XmlNode current = node;
    while (true) {
      final parent = current.parent;
      if (parent == null || parent is XmlDocument) {
        break;
      }
      var index = 0;
      var seen = 0;
      for (final child in parent.children) {
        if (_skips(child)) {
          continue;
        }
        seen += 1;
        if (identical(child, current)) {
          index = seen;
          break;
        }
      }
      if (index == 0) {
        break;
      }
      final isText = current is XmlText;
      steps.insert(0, isText ? index * 2 - 1 : index * 2);
      // The body itself contributes no step; its children do.
      if (_isBody(parent)) {
        break;
      }
      current = parent;
    }
    return steps;
  }

  bool _isBody(final XmlNode node) => node is XmlElement && node.name.local.toLowerCase() == 'body';

  bool _skips(final XmlNode node) => node is XmlText && node.value.isEmpty;

  /// CFI of the character at [offset] (like the JS encode from a text
  /// node plus offset). The id assertion comes from the nearest
  /// element ancestor carrying an `id`.
  EpubCfi cfiForOffset(final int offset) {
    final node = _textNodeAt(offset);
    if (node == null) {
      throw RangeError.range(offset, 0, 0, 'offset', 'empty document');
    }
    final steps = _stepsFor(node);
    String? id;
    XmlElement? element = node.parent is XmlElement ? node.parent as XmlElement : null;
    while (element != null && !_isBody(element)) {
      final idAttr = element.attributes.where(
        (final attribute) => attribute.name.local.toLowerCase() == 'id',
      );
      if (idAttr.isNotEmpty) {
        id = idAttr.first.value;
        break;
      }
      element = element.parent is XmlElement ? element.parent as XmlElement : null;
    }
    return EpubCfi.simple(steps: steps, charOffset: offset - offsetOf(node), idAssertion: id);
  }

  /// Character offset of a parsed [cfi] (the decode path): resolves
  /// the path against the tree; a final element step addresses the
  /// start of its first text node.
  int? offsetForCfi(final EpubCfi cfi) {
    final steps = cfi.steps;
    if (steps.isEmpty) {
      return null;
    }
    // Text step: odd numbers map to text children, index = (step+1)/2.
    // The EPUB child index counts ALL nodes (whitespace text nodes
    // included), exactly like `_stepsFor` on the encode side.
    XmlNode current = _body;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final isText = step.isOdd;
      final childIndex = isText ? (step + 1) ~/ 2 : step ~/ 2;
      final children = current.children.where((final c) => !_skips(c)).toList();
      if (childIndex < 1 || childIndex > children.length) {
        return null;
      }
      final child = children[childIndex - 1];
      if (isText && child is XmlText) {
        if (i == steps.length - 1) {
          final len = child.value.length;
          return offsetOf(child) + math.min(cfi.charOffset, len);
        }
        return null;
      }
      if (!isText && child is XmlElement) {
        current = child;
        continue;
      }
      return null;
    }
    return offsetOf(current);
  }
}
