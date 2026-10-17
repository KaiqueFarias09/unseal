import 'dart:typed_data';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart' as events;

import '../../foundation/text/xml_encoding.dart';
import 'page_document.dart';
import 'page_exception.dart';

/// Input and structure bounds for the supported PAGE subset. Hostile or
/// oversized documents fail with [PageXmlException] before allocations.
const int _maxInputBytes = 32 * 1024 * 1024;
const int _maxElements = 1048576;
const int _maxDepth = 128;
const int _maxElementsPerPage = 65536;
const int _maxRegionsPerPage = 16384;
const int _maxLinesPerRegion = 16384;
const int _maxWordsPerLine = 4096;
const int _maxPointsPerPolygon = 4096;
const int _maxAlternativesPerNode = 32;
const int _maxContentLength = 4096;
const int _maxOrderEntriesPerPage = 16384;
const int _maxGroupDepth = 8;

/// The one namespace the subset supports: PAGE content 2019-07-15.
const String pageXmlNamespace = 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15';

/// The fifteen region element names the 2019 schema defines.
final List<String> _regionElements = <String>[
  for (final kind in PageXmlRegionKind.values) kind.elementName,
];

/// Parses PAGE XML bytes into a [PageXmlDocument] under the declared
/// 2019-07-15 subset: metadata, page identity and dimensions, all
/// region kinds, native polygons and baselines, the ReadingOrder tree,
/// and TextEquiv alternatives with confidence and language.
///
/// Elements outside the subset (alternative images, layers, relations,
/// text styles, labels, roles, glyph trees) are ignored as data;
/// schema-required content the subset cannot serve — a missing
/// Metadata field, malformed points, confidence outside 0–1, a
/// TextEquiv without Unicode, an id collision, a reading-order
/// reference without a target, a duplicate reference, or a cyclic
/// group — fails typed. Every traversal is bounded; hostile or
/// oversized input fails with [PageXmlException] instead of exhausting
/// the caller.
PageXmlDocument parsePageXmlDocument(final Uint8List bytes) {
  if (bytes.length > _maxInputBytes) {
    throw const PageXmlException('PAGE input exceeds the 32 MiB limit.');
  }
  final String text;
  try {
    text = decodeXmlText(bytes);
    _validateXmlBounds(text);
  } on XmlException {
    throw const PageXmlException('PAGE input is not well-formed XML.');
  }
  final XmlDocument document;
  try {
    document = XmlDocument.parse(text);
  } on XmlException {
    throw const PageXmlException('PAGE input is not well-formed XML.');
  }
  final root = document.rootElement;
  if (root.name.local != 'PcGts') {
    throw const PageXmlException('PAGE document must have a PcGts root element.');
  }
  if (root.name.namespaceUri != pageXmlNamespace) {
    throw PageXmlUnsupportedFeatureException(
      'PAGE root namespace ${root.name.namespaceUri ?? '(none)'} is outside '
      'the supported 2019-07-15 subset.',
    );
  }

  final metadata = _child(root, 'Metadata');
  if (metadata == null) {
    throw const PageXmlException('PAGE document declares no Metadata.');
  }
  final creator = _requiredText(metadata, 'Creator');
  final created = _requiredText(metadata, 'Created');
  final lastChange = _requiredText(metadata, 'LastChange');

  final pageNode = _child(root, 'Page');
  if (pageNode == null) {
    throw const PageXmlException('PAGE document declares no Page.');
  }

  final ids = <String>{};
  final page = _parsePage(pageNode, ids);
  final regionsById = <String, PageXmlRegion>{for (final region in page.regions) region.id: region};
  _validateReadingOrder(page.readingOrder, regionsById);

  return PageXmlDocument(
    pcGtsId: root.getAttribute('pcGtsId'),
    creator: creator,
    created: created,
    lastChange: lastChange,
    comments: _textOf(_child(metadata, 'Comments')),
    page: page,
  );
}

/// Event-level preflight: rejects oversized or too-deep documents
/// before the DOM exists, and bounds every Page subtree's element
/// count the way the parser's budgets will consume it.
void _validateXmlBounds(final String text) {
  var depth = 0;
  var elements = 0;
  var pageDepth = -1;
  var pageElements = 0;
  for (final event in events.parseEvents(text)) {
    if (event is events.XmlStartElementEvent) {
      if (++elements > _maxElements || depth >= _maxDepth) {
        throw const PageXmlException('PAGE XML exceeds its element or depth limit.');
      }
      if (event.name.split(':').last == 'Page' && pageDepth < 0) {
        pageDepth = depth;
        pageElements = 0;
      }
      if (pageDepth >= 0 && ++pageElements > _maxElementsPerPage) {
        throw const PageXmlException('PAGE page exceeds the element budget.');
      }
      if (!event.isSelfClosing) {
        depth++;
      } else if (pageDepth == depth) {
        pageDepth = -1;
      }
    } else if (event is events.XmlEndElementEvent) {
      depth--;
      if (depth == pageDepth) pageDepth = -1;
    }
  }
}

PageXmlPage _parsePage(final XmlElement node, final Set<String> ids) {
  final imageFilename = node.getAttribute('imageFilename');
  if (imageFilename == null || imageFilename.isEmpty) {
    throw const PageXmlException('PAGE page declares no imageFilename.');
  }
  final width = _requiredIntAttribute(node, 'imageWidth', 'page');
  final height = _requiredIntAttribute(node, 'imageHeight', 'page');

  final regions = <PageXmlRegion>[];
  for (final child in node.childElements) {
    final index = _regionElements.indexOf(child.name.local);
    if (index < 0) continue;
    if (regions.length >= _maxRegionsPerPage) {
      throw const PageXmlException('PAGE page exceeds the region limit.');
    }
    regions.add(_parseRegion(child, PageXmlRegionKind.values[index], ids));
  }

  final border = _child(node, 'Border');
  final printSpace = _child(node, 'PrintSpace');
  final readingOrderNode = _child(node, 'ReadingOrder');

  return PageXmlPage(
    imageFilename: imageFilename,
    width: width,
    height: height,
    xResolution: _doubleAttribute(node, 'imageXResolution'),
    yResolution: _doubleAttribute(node, 'imageYResolution'),
    resolutionUnit: node.getAttribute('imageResolutionUnit'),
    orientation: _doubleAttribute(node, 'orientation'),
    confidence: _confidenceAttribute(node, 'conf'),
    type: node.getAttribute('type'),
    primaryLanguage: node.getAttribute('primaryLanguage'),
    border: border == null ? null : _polygon(border, ids),
    printSpace: printSpace == null ? null : _polygon(printSpace, ids),
    readingOrder: readingOrderNode == null ? null : _parseReadingOrder(readingOrderNode, ids),
    regions: regions,
  );
}

PageXmlRegion _parseRegion(
  final XmlElement node,
  final PageXmlRegionKind kind,
  final Set<String> ids,
) {
  final id = _declareId(node, ids, 'region');
  final polygon = _polygon(_requiredChild(node, 'Coords'), ids);
  final isText = kind == PageXmlRegionKind.text;
  final lines = <PageXmlTextLine>[];
  PageXmlTextContent? text;
  if (isText) {
    for (final child in node.childElements) {
      if (child.name.local == 'TextLine') {
        if (lines.length >= _maxLinesPerRegion) {
          throw const PageXmlException('PAGE region exceeds the text-line limit.');
        }
        lines.add(_parseTextLine(child, ids));
      }
    }
    text = _textContentOf(node);
  }

  return PageXmlRegion(
    kind: kind,
    id: id,
    polygon: polygon,
    orientation: _doubleAttribute(node, 'orientation'),
    readingOrientation: _doubleAttribute(node, 'readingOrientation'),
    textType: node.getAttribute('type'),
    primaryLanguage: node.getAttribute('primaryLanguage'),
    secondaryLanguage: node.getAttribute('secondaryLanguage'),
    readingDirection: node.getAttribute('readingDirection'),
    textLineOrder: node.getAttribute('textLineOrder'),
    continuation: _boolAttribute(node, 'continuation'),
    custom: node.getAttribute('custom'),
    text: text,
    lines: lines,
  );
}

PageXmlTextLine _parseTextLine(final XmlElement node, final Set<String> ids) {
  final id = _declareId(node, ids, 'text line');
  final polygon = _polygon(_requiredChild(node, 'Coords'), ids);
  final words = <PageXmlWord>[];
  final baselineNode = _child(node, 'Baseline');
  for (final child in node.childElements) {
    if (child.name.local != 'Word') continue;
    if (words.length >= _maxWordsPerLine) {
      throw const PageXmlException('PAGE text line exceeds the word limit.');
    }
    words.add(_parseWord(child, ids));
  }

  return PageXmlTextLine(
    id: id,
    polygon: polygon,
    baseline: baselineNode == null ? null : _baseline(baselineNode),
    primaryLanguage: node.getAttribute('primaryLanguage'),
    readingDirection: node.getAttribute('readingDirection'),
    index: _intAttribute(node, 'index'),
    text: _textContentOf(node),
    words: words,
  );
}

PageXmlWord _parseWord(final XmlElement node, final Set<String> ids) {
  final id = _declareId(node, ids, 'word');

  return PageXmlWord(
    id: id,
    polygon: _polygon(_requiredChild(node, 'Coords'), ids),
    language: node.getAttribute('language'),
    readingDirection: node.getAttribute('readingDirection'),
    text: _textContentOf(node),
  );
}

PageXmlPolygon _polygon(final XmlElement coords, final Set<String> ids) {
  final raw = coords.getAttribute('points');
  if (raw == null || raw.isEmpty) {
    throw const PageXmlException('PAGE Coords declares no points.');
  }
  final tokens = raw.trim().split(' ');
  if (tokens.length < 2 || tokens.length > _maxPointsPerPolygon) {
    throw PageXmlException(
      'PAGE polygon carries ${tokens.length} points, outside the 2..4096 range.',
    );
  }
  final points = <(int, int)>[];
  for (final token in tokens) {
    final parts = token.split(',');
    if (parts.length != 2) {
      throw PageXmlException('PAGE point "$token" is not an x,y pair.');
    }
    final x = int.tryParse(parts[0]);
    final y = int.tryParse(parts[1]);
    if (x == null || y == null || x < 0 || y < 0) {
      throw PageXmlException('PAGE point "$token" is not a non-negative integer pair.');
    }
    points.add((x, y));
  }

  return PageXmlPolygon(points: points, confidence: _confidenceAttribute(coords, 'conf'));
}

PageXmlBaseline _baseline(final XmlElement node) {
  final raw = node.getAttribute('points');
  if (raw == null || raw.isEmpty) {
    throw const PageXmlException('PAGE Baseline declares no points.');
  }
  final tokens = raw.trim().split(' ');
  if (tokens.length < 2 || tokens.length > _maxPointsPerPolygon) {
    throw PageXmlException(
      'PAGE baseline carries ${tokens.length} points, outside the 2..4096 range.',
    );
  }
  final points = <(int, int)>[];
  for (final token in tokens) {
    final parts = token.split(',');
    if (parts.length != 2) {
      throw PageXmlException('PAGE baseline point "$token" is not an x,y pair.');
    }
    final x = int.tryParse(parts[0]);
    final y = int.tryParse(parts[1]);
    if (x == null || y == null || x < 0 || y < 0) {
      throw PageXmlException('PAGE baseline point "$token" is not a non-negative integer pair.');
    }
    points.add((x, y));
  }

  return PageXmlBaseline(points: points, confidence: _confidenceAttribute(node, 'conf'));
}

PageXmlTextContent? _textContentOf(final XmlElement node) {
  final alternatives = <PageXmlTextEquiv>[];
  for (final child in node.childElements) {
    if (child.name.local != 'TextEquiv') continue;
    if (alternatives.length >= _maxAlternativesPerNode) {
      throw const PageXmlException('PAGE node exceeds the TextEquiv alternative limit.');
    }
    final unicode = _child(child, 'Unicode');
    if (unicode == null) {
      throw const PageXmlException('PAGE TextEquiv declares no Unicode content.');
    }
    final content = unicode.innerText;
    if (content.length > _maxContentLength) {
      throw const PageXmlException('PAGE TextEquiv content exceeds the 4096-character limit.');
    }
    final index = _intAttribute(child, 'index');
    if (index != null && index < 0) {
      throw const PageXmlException('PAGE TextEquiv index must not be negative.');
    }
    alternatives.add(
      PageXmlTextEquiv(
        unicode: content,
        plainText: _textOf(_child(child, 'PlainText')),
        index: index,
        confidence: _confidenceAttribute(child, 'conf'),
      ),
    );
  }
  if (alternatives.isEmpty) return null;

  return PageXmlTextContent(alternatives: alternatives);
}

PageXmlReadingOrder _parseReadingOrder(final XmlElement node, final Set<String> ids) {
  final groupNode = node.childElements.isEmpty ? null : node.childElements.first;
  if (groupNode == null ||
      (groupNode.name.local != 'OrderedGroup' && groupNode.name.local != 'UnorderedGroup')) {
    throw const PageXmlException('PAGE ReadingOrder holds no OrderedGroup or UnorderedGroup root.');
  }
  var entries = 0;
  final root = _parseGroup(
    groupNode,
    ids,
    ordered: groupNode.name.local == 'OrderedGroup',
    counter: () {
      if (++entries > _maxOrderEntriesPerPage) {
        throw const PageXmlException('PAGE ReadingOrder exceeds the entry limit.');
      }
    },
    depth: 1,
  );

  return PageXmlReadingOrder(root: root, confidence: _confidenceAttribute(node, 'conf'));
}

PageXmlGroup _parseGroup(
  final XmlElement node,
  final Set<String> ids, {
  required final bool ordered,
  required final void Function() counter,
  required final int depth,
}) {
  if (depth > _maxGroupDepth) {
    throw const PageXmlException('PAGE reading order exceeds the group nesting limit.');
  }
  final id = _declareId(node, ids, 'reading order group');
  final indexedStyle = ordered;
  final items = <PageXmlOrderNode>[];
  var order = 0;
  void walk(final XmlElement parent) {
    for (final child in parent.childElements) {
      counter();
      switch (child.name.local) {
        case 'RegionRefIndexed' when indexedStyle:
          items.add(
            PageXmlRegionRef(
              regionRef: _requiredAttribute(child, 'regionRef'),
              index: _requiredIntAttribute(child, 'index', 'RegionRefIndexed'),
              documentOrder: order++,
            ),
          );
        case 'RegionRef' when !indexedStyle:
          items.add(
            PageXmlRegionRef(
              regionRef: _requiredAttribute(child, 'regionRef'),
              index: null,
              documentOrder: order++,
            ),
          );
        case 'OrderedGroupIndexed' when indexedStyle:
          items.add(
            _nestedGroup(
              child,
              ids,
              ordered: true,
              indexed: true,
              counter: counter,
              order: order++,
              depth: depth,
            ),
          );
        case 'UnorderedGroupIndexed' when indexedStyle:
          items.add(
            _nestedGroup(
              child,
              ids,
              ordered: false,
              indexed: true,
              counter: counter,
              order: order++,
              depth: depth,
            ),
          );
        case 'OrderedGroup' when !indexedStyle:
          items.add(
            _nestedGroup(
              child,
              ids,
              ordered: true,
              indexed: false,
              counter: counter,
              order: order++,
              depth: depth,
            ),
          );
        case 'UnorderedGroup' when !indexedStyle:
          items.add(
            _nestedGroup(
              child,
              ids,
              ordered: false,
              indexed: false,
              counter: counter,
              order: order++,
              depth: depth,
            ),
          );
        case 'UserDefined' || 'Labels':
          break;
        default:
          throw PageXmlException(
            'PAGE reading order element "${child.name.local}" is not allowed '
            'inside ${indexedStyle ? 'an ordered' : 'an unordered'} group.',
          );
      }
    }
  }

  walk(node);

  return PageXmlGroup(
    id: id,
    isOrdered: ordered,
    items: items,
    regionRef: node.getAttribute('regionRef'),
    caption: node.getAttribute('caption'),
    index: null,
    documentOrder: 0,
  );
}

PageXmlGroup _nestedGroup(
  final XmlElement node,
  final Set<String> ids, {
  required final bool ordered,
  required final bool indexed,
  required final void Function() counter,
  required final int order,
  required final int depth,
}) {
  final group = _parseGroup(node, ids, ordered: ordered, counter: counter, depth: depth + 1);

  return PageXmlGroup(
    id: group.id,
    isOrdered: ordered,
    items: group.items,
    regionRef: node.getAttribute('regionRef'),
    caption: node.getAttribute('caption'),
    index: indexed ? _requiredIntAttribute(node, 'index', node.name.local) : null,
    documentOrder: order,
  );
}

/// Validates the parsed reading order against the page's regions:
/// every reference resolves, no region is referenced twice, and no
/// group contains itself. Group-to-region links must resolve too.
void _validateReadingOrder(
  final PageXmlReadingOrder? order,
  final Map<String, PageXmlRegion> regions,
) {
  if (order == null) return;
  final groupIds = <String>{};
  void collectIds(final PageXmlGroup group) {
    if (!groupIds.add(group.id)) {
      throw PageXmlException('PAGE reading order declares group "${group.id}" twice.');
    }
    for (final item in group.items) {
      if (item is PageXmlGroup) collectIds(item);
    }
  }

  collectIds(order.root);

  final referenced = <String>{};
  void verify(final PageXmlGroup group) {
    final link = group.regionRef;
    if (link != null && !regions.containsKey(link)) {
      throw PageXmlException(
        'PAGE reading order group "${group.id}" links to unknown region "$link".',
      );
    }
    if (_containsSelf(group, group.id)) {
      throw PageXmlException('PAGE reading order group "${group.id}" contains itself.');
    }
    for (final item in group.items) {
      if (item is PageXmlGroup) {
        verify(item);
        continue;
      }
      final ref = (item as PageXmlRegionRef).regionRef;
      if (!regions.containsKey(ref)) {
        throw PageXmlException('PAGE reading order references unknown region "$ref".');
      }
      if (!referenced.add(ref)) {
        throw PageXmlException('PAGE reading order references region "$ref" more than once.');
      }
    }
  }

  verify(order.root);
}

/// Whether any nested group of [group] re-declares [group]'s own id —
/// the cycle shape the model can represent but the contract refuses.
bool _containsSelf(final PageXmlGroup group, final String id) {
  for (final item in group.items) {
    if (item is! PageXmlGroup) continue;
    if (item.id == id) return true;
    if (_containsSelf(item, id)) return true;
  }

  return false;
}

String _declareId(final XmlElement node, final Set<String> ids, final String what) {
  final id = node.getAttribute('id');
  if (id == null || id.isEmpty) {
    throw PageXmlException('PAGE $what declares no id.');
  }
  if (!ids.add(id)) {
    throw PageXmlException('PAGE declares id "$id" more than once.');
  }

  return id;
}

XmlElement _requiredChild(final XmlElement parent, final String local) {
  final child = _child(parent, local);
  if (child == null) {
    throw PageXmlException('PAGE ${parent.name.local} declares no $local.');
  }

  return child;
}

String _requiredAttribute(final XmlElement node, final String name) {
  final value = node.getAttribute(name);
  if (value == null || value.isEmpty) {
    throw PageXmlException('PAGE ${node.name.local} declares no $name.');
  }

  return value;
}

String _requiredText(final XmlElement parent, final String local) {
  final node = _requiredChild(parent, local);
  final value = node.innerText;

  return value;
}

String? _textOf(final XmlElement? node) {
  if (node == null) return null;
  final value = node.innerText;

  return value.isEmpty ? null : value;
}

int _requiredIntAttribute(final XmlElement node, final String name, final String what) {
  final raw = node.getAttribute(name);
  if (raw == null) {
    throw PageXmlException('PAGE $what declares no $name.');
  }
  final value = int.tryParse(raw);
  if (value == null || value < 0) {
    throw PageXmlException('PAGE attribute $name="$raw" is not a non-negative integer.');
  }

  return value;
}

int? _intAttribute(final XmlElement node, final String name) {
  final raw = node.getAttribute(name);
  if (raw == null) return null;

  return int.tryParse(raw);
}

double? _doubleAttribute(final XmlElement node, final String name) {
  final raw = node.getAttribute(name);
  if (raw == null) return null;
  final value = double.tryParse(raw);
  if (value == null || !value.isFinite) {
    throw PageXmlException('PAGE attribute $name="$raw" is not a finite number.');
  }

  return value;
}

double? _confidenceAttribute(final XmlElement node, final String name) {
  final value = _doubleAttribute(node, name);
  if (value == null) return null;
  if (value < 0 || value > 1) {
    throw PageXmlException('PAGE attribute $name="$value" lies outside 0..1.');
  }

  return value;
}

bool? _boolAttribute(final XmlElement node, final String name) {
  final raw = node.getAttribute(name);
  if (raw == null) return null;
  if (raw == 'true') return true;
  if (raw == 'false') return false;
  throw PageXmlException('PAGE attribute $name="$raw" is not a boolean.');
}

XmlElement? _child(final XmlElement parent, final String local) {
  for (final node in parent.childElements) {
    if (node.name.local == local) return node;
  }

  return null;
}
