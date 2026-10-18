import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../foundation/text/xml_encoding.dart';
import 'hocr_document.dart';
import 'hocr_exception.dart';
import 'hocr_input_limits.dart';
import 'hocr_title.dart';

/// Input and structure bounds for the supported hOCR subset. Hostile or
/// oversized documents fail with [HocrException] before the DOM exists and
/// again while the tree is walked.
const int _maxDepth = 128;
const int _maxElements = 1048576;
const int _maxElementsPerPage = 65536;
const int _maxAttributesPerElement = 64;
const int _maxTitleLength = 4096;
const int _maxClassLength = 1024;
const int _maxPropertiesPerElement = 64;
const int _maxTokensPerProperty = 256;
const int _maxPages = 4096;
const int _maxBlocksPerPage = 16384;
const int _maxParagraphsPerContainer = 16384;
const int _maxLinesPerContainer = 16384;
const int _maxWordsPerLine = 4096;
const int _maxWordsPerDocument = 1048576;
const int _maxTextLength = 4096;
const int _maxBaselineCoefficients = 8;
const int _maxCoordinate = 0x7FFFFFFF;

/// HTML elements that never have content and never nest.
const Set<String> _voidElements = <String>{
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

/// The hOCR class tokens Tesseract 4 and 5 write on line elements in place
/// of `ocr_line` to carry the block's logical type.
const Set<String> _lineRoleTokens = <String>{'ocr_header', 'ocr_caption', 'ocr_textfloat'};

/// The metadata names the subset reads from `head`.
const Set<String> _metadataNames = <String>{
  'ocr-system',
  'ocr-capabilities',
  'ocr-number-of-pages',
  'ocr-langs',
  'ocr-scripts',
};

/// Parses hOCR (HTML or XHTML) bytes into an [HocrDocument] under the
/// subset `doc/hocr.md` fixes: producer metadata, pages, content areas,
/// paragraphs, lines and words with the nesting the producer declared,
/// integer boxes, native baselines, text angles, scan resolution, the
/// 0..100 word confidence, and every unconsumed title property verbatim.
///
/// Other hOCR classes are transparent containers; `order` and `cflow`
/// fail with [HocrUnsupportedFeatureException]; corruption, inverted
/// hierarchy, malformed titles and every exceeded limit fail with
/// [HocrException]. Every traversal is bounded, and the byte, depth,
/// element, attribute and title budgets are checked over the raw markup
/// before any tree is allocated.
HocrDocument parseHocrDocument(final Uint8List bytes) {
  checkHocrInputLength(bytes.length);
  final text = decodeXmlText(bytes);
  _preflight(text);
  final document = html_parser.parse(text);
  final metadata = _readMetadata(document);
  final context = _ParseContext();
  final pages = <HocrPage>[];
  final root = document.documentElement;
  if (root != null) _findPages(root, pages, context);
  if (pages.isEmpty) {
    throw const HocrException('hOCR document declares no ocr_page element.');
  }

  return HocrDocument(
    system: metadata['ocr-system'],
    capabilities: _tokens(metadata['ocr-capabilities']),
    numberOfPages: _optionalInt(metadata['ocr-number-of-pages']),
    languages: _tokens(metadata['ocr-langs']),
    scripts: _tokens(metadata['ocr-scripts']),
    pages: pages,
  );
}

/// Linear preflight over the raw markup: counts start tags, tracks raw
/// nesting, bounds attributes per tag and the `title`/`class` lengths,
/// and bounds the element count of every `ocr_page` subtree — all before
/// the HTML parser allocates a node.
void _preflight(final String text) {
  final n = text.length;
  var i = 0;
  final openTags = <String>[];
  var elements = 0;
  var pageDepth = -1;
  var pageElements = 0;
  while (true) {
    final lt = text.indexOf('<', i);
    if (lt < 0 || lt + 1 >= n) break;
    i = lt + 1;
    final lead = text.codeUnitAt(i);
    if (lead == 0x21) {
      if (text.startsWith('--', i + 1)) {
        final end = text.indexOf('-->', i + 3);
        if (end < 0) return;
        i = end + 3;
      } else {
        final end = text.indexOf('>', i);
        if (end < 0) return;
        i = end + 1;
      }
      continue;
    }
    if (lead == 0x3F) {
      final end = text.indexOf('>', i);
      if (end < 0) return;
      i = end + 1;
      continue;
    }
    if (lead == 0x2F) {
      final end = text.indexOf('>', i);
      if (end < 0) return;
      i = end + 1;
      final closingName = text.substring(lt + 2, end).trim().toLowerCase();
      final matching = openTags.lastIndexOf(closingName);
      if (matching >= 0) {
        openTags.removeRange(matching, openTags.length);
        if (openTags.length <= pageDepth) pageDepth = -1;
      }
      continue;
    }
    if (!_isAsciiLetter(lead)) continue;
    final nameStart = i;
    while (i < n && _isNameChar(text.codeUnitAt(i))) {
      i++;
    }
    final name = text.substring(nameStart, i).toLowerCase();
    if (++elements > _maxElements) {
      throw const HocrException('hOCR markup exceeds the element limit.');
    }
    if (openTags.length >= _maxDepth) {
      throw const HocrException('hOCR markup exceeds the nesting depth limit.');
    }
    var attributes = 0;
    var isPage = false;
    while (i < n) {
      final unit = text.codeUnitAt(i);
      if (_isSpace(unit)) {
        i++;
        continue;
      }
      if (unit == 0x3E) {
        i++;
        break;
      }
      if (unit == 0x2F) {
        i++;
        if (i < n && text.codeUnitAt(i) == 0x3E) {
          i++;
          break;
        }
        continue;
      }
      final attributeStart = i;
      while (i < n) {
        final v = text.codeUnitAt(i);
        if (_isSpace(v) || v == 0x3D || v == 0x3E || v == 0x2F) break;
        i++;
      }
      final attribute = text.substring(attributeStart, i).toLowerCase();
      if (++attributes > _maxAttributesPerElement) {
        throw const HocrException('hOCR element exceeds the attribute limit.');
      }
      while (i < n && _isSpace(text.codeUnitAt(i))) {
        i++;
      }
      String? value;
      if (i < n && text.codeUnitAt(i) == 0x3D) {
        i++;
        while (i < n && _isSpace(text.codeUnitAt(i))) {
          i++;
        }
        if (i < n) {
          final quote = text.codeUnitAt(i);
          if (quote == 0x22 || quote == 0x27) {
            final close = text.indexOf(String.fromCharCode(quote), i + 1);
            value = text.substring(i + 1, close < 0 ? n : close);
            i = close < 0 ? n : close + 1;
          } else {
            final valueStart = i;
            while (i < n) {
              final v = text.codeUnitAt(i);
              if (_isSpace(v) || v == 0x3E) break;
              i++;
            }
            value = text.substring(valueStart, i);
          }
        }
      }
      if (attribute == 'title' && value != null && value.length > _maxTitleLength) {
        throw const HocrException('hOCR title attribute exceeds the 4096-character limit.');
      }
      if (attribute == 'class' && value != null) {
        if (value.length > _maxClassLength) {
          throw const HocrException('hOCR class attribute exceeds the 1024-character limit.');
        }
        if (_hasToken(_classForPreflight(value), 'ocr_page')) isPage = true;
      }
    }
    if (isPage && pageDepth < 0) {
      pageDepth = openTags.length;
      pageElements = 0;
    }
    if (pageDepth >= 0 && ++pageElements > _maxElementsPerPage) {
      throw const HocrException('hOCR page exceeds the element budget.');
    }
    // HTML ignores the self-closing flag on non-void elements, including
    // XHTML input parsed through this same HTML parser. Count them as open.
    if (!_voidElements.contains(name)) {
      openTags.add(name);
      if (name == 'script' || name == 'style') {
        final close = _indexOfCloseTag(text, name, i);
        if (close < 0) return;
        i = close;
      }
    } else if (isPage && pageDepth == openTags.length) {
      pageDepth = -1;
    }
  }
}

// Only numeric references and these four named references can produce
// ASCII characters in an hOCR role token or its ASCII whitespace boundary.
// Decode them before counting a page subtree; the bounded class attribute
// needs no HTML tree just to recognize an escaped `ocr_page` token.
final _classReferences = RegExp(
  r'&(#(?:[xX][0-9a-fA-F]+|[0-9]+);?|lowbar;|UnderBar;|Tab;|NewLine;)',
);

String _classForPreflight(final String value) => value.replaceAllMapped(_classReferences, (
  final match,
) {
  final reference = match[1]!;
  if (reference.startsWith('#')) {
    final digits = reference.endsWith(';')
        ? reference.substring(0, reference.length - 1)
        : reference;
    final hexadecimal = digits.startsWith('#x') || digits.startsWith('#X');
    final code = int.tryParse(digits.substring(hexadecimal ? 2 : 1), radix: hexadecimal ? 16 : 10);
    return code != null && code > 0 && code < 128 ? String.fromCharCode(code) : match[0]!;
  }

  return switch (reference) {
    'lowbar;' || 'UnderBar;' => '_',
    'Tab;' => '\t',
    'NewLine;' => '\n',
    _ => match[0]!,
  };
});

/// The index of `</name` at or after [from], case-insensitive, or -1.
int _indexOfCloseTag(final String text, final String name, final int from) {
  var i = from;
  while (true) {
    final lt = text.indexOf('</', i);
    if (lt < 0) return -1;
    final end = lt + 2 + name.length;
    if (end <= text.length && text.substring(lt + 2, end).toLowerCase() == name) return lt;
    i = lt + 2;
  }
}

bool _hasToken(final String classValue, final String token) {
  for (final candidate in _tokens(classValue)) {
    if (candidate == token) return true;
  }

  return false;
}

bool _isAsciiLetter(final int unit) =>
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);

bool _isNameChar(final int unit) =>
    _isAsciiLetter(unit) ||
    (unit >= 0x30 && unit <= 0x39) ||
    unit == 0x2D ||
    unit == 0x3A ||
    unit == 0x5F;

bool _isSpace(final int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C;

/// Splits on ASCII whitespace, dropping empty tokens.
List<String> _tokens(final String? value) {
  if (value == null) return const <String>[];
  final result = <String>[];
  var start = -1;
  for (var i = 0; i <= value.length; i++) {
    final isBoundary = i == value.length || _isSpace(value.codeUnitAt(i));
    if (isBoundary) {
      if (start >= 0) result.add(value.substring(start, i));
      start = -1;
    } else if (start < 0) {
      start = i;
    }
  }

  return result;
}

int? _optionalInt(final String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (!_isDigits(trimmed) || trimmed.length > 10) return null;

  return int.tryParse(trimmed);
}

Map<String, String> _readMetadata(final dom.Document document) {
  final result = <String, String>{};
  for (final meta in document.querySelectorAll('meta')) {
    final name = _attribute(meta, 'name')?.toLowerCase();
    if (name == null || !_metadataNames.contains(name)) continue;
    if (result.containsKey(name)) {
      throw HocrException('hOCR declares the $name metadata more than once.');
    }
    result[name] = _attribute(meta, 'content') ?? '';
  }

  return result;
}

String? _attribute(final dom.Element element, final String name) {
  final direct = element.attributes[name];
  if (direct != null) return direct;
  for (final entry in element.attributes.entries) {
    if (entry.key.toString() == name) return entry.value;
  }

  return null;
}

final class _ParseContext {
  int pages = 0;
  int words = 0;
}

enum _Role { page, block, paragraph, line, word }

/// Which role an element plays, or null for a transparent element (a
/// non-hOCR tag or an hOCR class outside the subset).
(String, _Role)? _classify(final dom.Element element) {
  final classValue = _attribute(element, 'class');
  if (classValue == null) return null;
  String? roleToken;
  _Role? role;
  for (final token in _tokens(classValue)) {
    if (!token.startsWith('ocr_') && !token.startsWith('ocrx_')) continue;
    final candidate = switch (token) {
      'ocr_page' => _Role.page,
      'ocr_carea' || 'ocrx_block' || 'ocr_column' => _Role.block,
      'ocr_par' => _Role.paragraph,
      'ocr_line' || 'ocrx_line' => _Role.line,
      'ocrx_word' => _Role.word,
      _ => _lineRoleTokens.contains(token) && !_hasLineDescendant(element) ? _Role.line : null,
    };
    if (candidate == null) continue;
    if (role != null) {
      throw HocrException(
        'hOCR element declares both "$roleToken" and "$token"; the role is ambiguous.',
      );
    }
    role = candidate;
    roleToken = token;
  }
  if (role == null) {
    if (_tokens(
      classValue,
    ).any((final token) => token.startsWith('ocr_') || token.startsWith('ocrx_'))) {
      final properties = parseHocrTitle(
        _attribute(element, 'title') ?? '',
        maxProperties: _maxPropertiesPerElement,
        maxTokens: _maxTokensPerProperty,
      );
      for (final property in properties) {
        if (property.name == 'order' || property.name == 'cflow') {
          throw HocrUnsupportedFeatureException(
            'hOCR ${property.name} asks for a reading order Unseal does not reconstruct.',
          );
        }
      }
    }

    return null;
  }

  return (roleToken!, role);
}

/// Whether any descendant declares `ocr_line` or `ocrx_line`.
bool _hasLineDescendant(final dom.Element element) {
  for (final child in element.children) {
    final classValue = _attribute(child, 'class');
    if (classValue != null &&
        (_hasToken(classValue, 'ocr_line') || _hasToken(classValue, 'ocrx_line'))) {
      return true;
    }
    if (_hasLineDescendant(child)) return true;
  }

  return false;
}

/// Finds `ocr_page` elements anywhere in the tree; role elements outside a
/// page are ignored and never descended into.
void _findPages(
  final dom.Element element,
  final List<HocrPage> pages,
  final _ParseContext context,
) {
  if (element.localName == 'del') return;
  final classified = _classify(element);
  if (classified == null) {
    for (final child in element.children) {
      _findPages(child, pages, context);
    }

    return;
  }
  if (classified.$2 != _Role.page) return;
  if (++context.pages > _maxPages) {
    throw const HocrException('hOCR document exceeds the page limit.');
  }
  pages.add(_parsePage(element, classified.$1, context));
}

final class _Attributes {
  _Attributes(final dom.Element element, final String roleToken, this.role)
    : tagName = element.localName ?? '',
      className = roleToken,
      id = _attribute(element, 'id'),
      language = _attribute(element, 'lang'),
      xmlLanguage = _attribute(element, 'xml:lang'),
      direction = _attribute(element, 'dir'),
      title = _attribute(element, 'title') ?? '' {
    if (title.length > _maxTitleLength) {
      throw const HocrException('hOCR title attribute exceeds the 4096-character limit.');
    }
    final parsed = parseHocrTitle(
      title,
      maxProperties: _maxPropertiesPerElement,
      maxTokens: _maxTokensPerProperty,
    );
    for (final property in parsed) {
      switch (property.name) {
        case 'order' || 'cflow':
          throw HocrUnsupportedFeatureException(
            'hOCR ${property.name} property on $className asks for a reading order '
            'Unseal does not reconstruct; document order is the only order.',
          );
        case 'bbox':
          box = _box(property.tokens);
        case 'textangle':
          textAngle = _single(property, _decimal);
        case 'baseline' when role == _Role.line:
          baseline = _baseline(property.tokens);
        case 'hardbreak' when role == _Role.line:
          hasHardBreak = _hardBreak(property.tokens);
        case 'x_wconf' when role == _Role.word:
          confidence = _confidence(property.tokens);
        case 'ppageno' when role == _Role.page:
          physicalPageNumber = _single(property, _uint);
        case 'lpageno' when role == _Role.page:
          logicalPageNumber = _single(property, (final token) => token);
        case 'image' when role == _Role.page:
          imageName = _optionalSingle(property);
        case 'imagemd5' when role == _Role.page:
          imageMd5 = _single(property, (final token) => token);
        case 'scan_res' when role == _Role.page:
          final resolution = _scanRes(property.tokens);
          scanResolutionX = resolution.$1;
          scanResolutionY = resolution.$2;
        default:
          properties[property.name] = property.tokens;
      }
    }
  }

  final _Role role;
  final String tagName;
  final String className;
  final String? id;
  final String? language;
  final String? xmlLanguage;
  final String? direction;
  final String title;
  final Map<String, List<String>> properties = <String, List<String>>{};
  HocrBox? box;
  double? textAngle;
  HocrBaseline? baseline;
  bool? hasHardBreak;
  HocrConfidence? confidence;
  int? physicalPageNumber;
  String? logicalPageNumber;
  String? imageName;
  String? imageMd5;
  int? scanResolutionX;
  int? scanResolutionY;

  HocrBox requireBox() {
    final value = box;
    if (value == null) {
      throw HocrException('hOCR $className declares no bbox.');
    }

    return value;
  }
}

HocrPage _parsePage(
  final dom.Element element,
  final String roleToken,
  final _ParseContext context,
) {
  final attributes = _Attributes(element, roleToken, _Role.page);
  final children = <HocrElement>[];
  final counters = _Counters();
  _walkContainer(element, _Role.page, children, counters, context);

  return HocrPage(
    className: attributes.className,
    tagName: attributes.tagName,
    id: attributes.id,
    box: attributes.box,
    language: attributes.language,
    xmlLanguage: attributes.xmlLanguage,
    direction: attributes.direction,
    textAngle: attributes.textAngle,
    properties: attributes.properties,
    physicalPageNumber: attributes.physicalPageNumber,
    logicalPageNumber: attributes.logicalPageNumber,
    imageName: attributes.imageName,
    imageMd5: attributes.imageMd5,
    scanResolutionX: attributes.scanResolutionX,
    scanResolutionY: attributes.scanResolutionY,
    children: children,
  );
}

final class _Counters {
  int blocks = 0;
  int paragraphs = 0;
  int lines = 0;
}

/// Walks [parent]'s element children, flattening transparent containers
/// into [into] and refusing inverted nesting.
void _walkContainer(
  final dom.Element parent,
  final _Role parentRole,
  final List<HocrElement> into,
  final _Counters counters,
  final _ParseContext context,
) {
  for (final child in parent.children) {
    if (child.localName == 'del') continue;
    final classified = _classify(child);
    if (classified == null) {
      _walkContainer(child, parentRole, into, counters, context);
      continue;
    }
    final (token, role) = classified;
    switch (role) {
      case _Role.page:
        throw const HocrException('hOCR ocr_page nests inside another element.');
      case _Role.block:
        if (parentRole != _Role.page) {
          throw HocrException(
            'hOCR $token nests inside ${parentRole.name}; blocks belong to the page.',
          );
        }
        if (++counters.blocks > _maxBlocksPerPage) {
          throw const HocrException('hOCR page exceeds the block limit.');
        }
        into.add(_parseBlock(child, token, context));
      case _Role.paragraph:
        if (parentRole != _Role.page && parentRole != _Role.block) {
          throw HocrException('hOCR $token nests inside ${parentRole.name}.');
        }
        if (++counters.paragraphs > _maxParagraphsPerContainer) {
          throw const HocrException('hOCR container exceeds the paragraph limit.');
        }
        into.add(_parseParagraph(child, token, context));
      case _Role.line:
        if (parentRole == _Role.line || parentRole == _Role.word) {
          throw HocrException('hOCR $token nests inside ${parentRole.name}.');
        }
        if (++counters.lines > _maxLinesPerContainer) {
          throw const HocrException('hOCR container exceeds the line limit.');
        }
        into.add(_parseLine(child, token, context));
      case _Role.word:
        throw HocrException('hOCR $token sits outside any line.');
    }
  }
}

HocrBlock _parseBlock(
  final dom.Element element,
  final String roleToken,
  final _ParseContext context,
) {
  final attributes = _Attributes(element, roleToken, _Role.block);
  final children = <HocrElement>[];
  _walkContainer(element, _Role.block, children, _Counters(), context);

  return HocrBlock(
    className: attributes.className,
    tagName: attributes.tagName,
    id: attributes.id,
    box: attributes.requireBox(),
    language: attributes.language,
    xmlLanguage: attributes.xmlLanguage,
    direction: attributes.direction,
    textAngle: attributes.textAngle,
    properties: attributes.properties,
    children: children,
  );
}

HocrParagraph _parseParagraph(
  final dom.Element element,
  final String roleToken,
  final _ParseContext context,
) {
  final attributes = _Attributes(element, roleToken, _Role.paragraph);
  final children = <HocrElement>[];
  _walkContainer(element, _Role.paragraph, children, _Counters(), context);

  return HocrParagraph(
    className: attributes.className,
    tagName: attributes.tagName,
    id: attributes.id,
    box: attributes.box,
    language: attributes.language,
    xmlLanguage: attributes.xmlLanguage,
    direction: attributes.direction,
    textAngle: attributes.textAngle,
    properties: attributes.properties,
    children: children,
  );
}

HocrLine _parseLine(
  final dom.Element element,
  final String roleToken,
  final _ParseContext context,
) {
  final attributes = _Attributes(element, roleToken, _Role.line);
  final words = <HocrWord>[];
  final text = _TextCollector();
  _walkLine(element, words, text, context);

  return HocrLine(
    className: attributes.className,
    tagName: attributes.tagName,
    id: attributes.id,
    box: attributes.requireBox(),
    language: attributes.language,
    xmlLanguage: attributes.xmlLanguage,
    direction: attributes.direction,
    textAngle: attributes.textAngle,
    properties: attributes.properties,
    baseline: attributes.baseline,
    hasHardBreak: attributes.hasHardBreak,
    text: text.toString(),
    hasAlternativeReadings: text.hasAlternatives || _hasAlternativeAncestor(element),
    words: words,
  );
}

bool _hasAlternativeAncestor(final dom.Element element) {
  for (var ancestor = element.parent; ancestor != null; ancestor = ancestor.parent) {
    if (ancestor.localName == 'ins' || ancestor.classes.contains('alternatives')) return true;
  }

  return false;
}

/// Walks a line's subtree: collects words (through transparent containers)
/// and the line's own text, refusing any other role inside.
void _walkLine(
  final dom.Node parent,
  final List<HocrWord> words,
  final _TextCollector text,
  final _ParseContext context,
) {
  for (final node in parent.nodes) {
    if (node is dom.Text) {
      text.add(node.data);
      continue;
    }
    if (node is! dom.Element) continue;
    final tag = node.localName;
    if (tag == 'script' || tag == 'style') continue;
    if (tag == 'del') {
      text.hasAlternatives = true;
      continue;
    }
    if (tag == 'ins') text.hasAlternatives = true;
    final classified = _classify(node);
    if (classified == null) {
      _walkLine(node, words, text, context);
      continue;
    }
    final (token, role) = classified;
    if (role != _Role.word) {
      throw HocrException('hOCR $token nests inside a line.');
    }
    if (words.length >= _maxWordsPerLine) {
      throw const HocrException('hOCR line exceeds the word limit.');
    }
    if (++context.words > _maxWordsPerDocument) {
      throw const HocrException('hOCR document exceeds the word limit.');
    }
    final word = _parseWord(node, token);
    words.add(word);
    text.add(word.text);
    if (word.hasAlternativeReadings) text.hasAlternatives = true;
  }
}

HocrWord _parseWord(final dom.Element element, final String roleToken) {
  final attributes = _Attributes(element, roleToken, _Role.word);
  final text = _TextCollector();
  _collectWordText(element, text);

  return HocrWord(
    className: attributes.className,
    tagName: attributes.tagName,
    id: attributes.id,
    box: attributes.box,
    language: attributes.language,
    xmlLanguage: attributes.xmlLanguage,
    direction: attributes.direction,
    textAngle: attributes.textAngle,
    properties: attributes.properties,
    confidence: attributes.confidence,
    text: text.toString(),
    hasAlternativeReadings: text.hasAlternatives,
  );
}

void _collectWordText(final dom.Node parent, final _TextCollector text) {
  for (final node in parent.nodes) {
    if (node is dom.Text) {
      text.add(node.data);
      continue;
    }
    if (node is! dom.Element) continue;
    final tag = node.localName;
    if (tag == 'script' || tag == 'style') continue;
    if (tag == 'del') {
      text.hasAlternatives = true;
      continue;
    }
    if (tag == 'ins') text.hasAlternatives = true;
    final classified = _classify(node);
    if (classified != null) {
      throw HocrException('hOCR ${classified.$1} nests inside a word.');
    }
    _collectWordText(node, text);
  }
}

final class _TextCollector {
  final StringBuffer _buffer = StringBuffer();
  bool hasAlternatives = false;

  void add(final String value) {
    if (_buffer.length + value.length > _maxTextLength) {
      throw const HocrException('hOCR text exceeds the 4096-code-unit limit.');
    }
    _buffer.write(value);
  }

  @override
  String toString() => _buffer.toString();
}

HocrBox _box(final List<String> tokens) {
  if (tokens.length != 4) {
    throw HocrException('hOCR bbox carries ${tokens.length} values; exactly four are required.');
  }
  final x0 = _uint(tokens[0]);
  final y0 = _uint(tokens[1]);
  final x1 = _uint(tokens[2]);
  final y1 = _uint(tokens[3]);
  if (x1 < x0 || y1 < y0) {
    throw HocrException('hOCR bbox ${tokens.join(' ')} is inverted.');
  }

  return HocrBox(x0: x0, y0: y0, x1: x1, y1: y1);
}

HocrBaseline _baseline(final List<String> tokens) {
  if (tokens.length < 2 || tokens.length > _maxBaselineCoefficients) {
    throw HocrException('hOCR baseline carries ${tokens.length} coefficients, outside 2..8.');
  }

  return HocrBaseline(coefficients: <double>[for (final token in tokens) _decimal(token)]);
}

HocrConfidence _confidence(final List<String> tokens) {
  if (tokens.length != 1) {
    throw HocrException('hOCR x_wconf carries ${tokens.length} values; exactly one is required.');
  }
  final token = tokens.single;
  if (_looksNumeric(token)) {
    // A numeric-shaped token must be a valid decimal; exponent, infinity
    // and digit noise are contract violations, never "unknown".
    final value = _decimal(token);
    if (value < 0 || value > 100) {
      throw HocrException('hOCR x_wconf $token lies outside 0..100.');
    }

    return HocrConfidence.value(value);
  }

  return HocrConfidence.unknown(token);
}

/// Whether [token] starts like a number, so only the full decimal grammar
/// can accept it.
bool _looksNumeric(final String token) {
  if (token.isEmpty) return false;
  final first = token.codeUnitAt(0);

  return (first >= 0x30 && first <= 0x39) || first == 0x2D || first == 0x2E;
}

(int, int) _scanRes(final List<String> tokens) {
  if (tokens.length == 1) {
    final both = _uint(tokens.single);

    return (both, both);
  }
  if (tokens.length != 2) {
    throw HocrException('hOCR scan_res carries ${tokens.length} values; two are required.');
  }

  return (_uint(tokens[0]), _uint(tokens[1]));
}

bool _hardBreak(final List<String> tokens) {
  if (tokens.length != 1 || (tokens.single != '0' && tokens.single != '1')) {
    throw HocrException('hOCR hardbreak must be 0 or 1, not "${tokens.join(' ')}".');
  }

  return tokens.single == '1';
}

T _single<T>(final HocrTitleProperty property, final T Function(String token) convert) {
  if (property.tokens.length != 1) {
    throw HocrException(
      'hOCR ${property.name} carries ${property.tokens.length} values; exactly one is required.',
    );
  }

  return convert(property.tokens.single);
}

String? _optionalSingle(final HocrTitleProperty property) {
  if (property.tokens.isEmpty) return null;
  if (property.tokens.length != 1) {
    throw HocrException(
      'hOCR ${property.name} carries ${property.tokens.length} values; at most one is allowed.',
    );
  }
  final value = property.tokens.single;

  return value.isEmpty ? null : value;
}

bool _isDigits(final String token) {
  if (token.isEmpty) return false;
  for (var i = 0; i < token.length; i++) {
    final unit = token.codeUnitAt(i);
    if (unit < 0x30 || unit > 0x39) return false;
  }

  return true;
}

int _uint(final String token) {
  if (!_isDigits(token) || token.length > 10) {
    throw HocrException('hOCR value "$token" is not a non-negative integer.');
  }
  final value = int.parse(token);
  if (value > _maxCoordinate) {
    throw HocrException('hOCR value "$token" exceeds the coordinate limit.');
  }

  return value;
}

/// `-?(digits(.digits*)?|.digits)`: the spec's `float`/`int` with a sign,
/// which rules out exponents, `inf`, `nan` and other non-finite spellings.
bool _isDecimalToken(final String token) {
  var i = 0;
  if (i < token.length && token.codeUnitAt(i) == 0x2D) i++;
  var digits = 0;
  while (i < token.length && token.codeUnitAt(i) >= 0x30 && token.codeUnitAt(i) <= 0x39) {
    i++;
    digits++;
  }
  if (i < token.length && token.codeUnitAt(i) == 0x2E) {
    i++;
    while (i < token.length && token.codeUnitAt(i) >= 0x30 && token.codeUnitAt(i) <= 0x39) {
      i++;
      digits++;
    }
  }

  return digits > 0 && i == token.length && token.length <= 64;
}

double _decimal(final String token) {
  if (!_isDecimalToken(token)) {
    throw HocrException('hOCR value "$token" is not a decimal number.');
  }
  final value = double.parse(token);
  if (!value.isFinite) {
    throw HocrException('hOCR value "$token" is not finite.');
  }

  return value;
}
