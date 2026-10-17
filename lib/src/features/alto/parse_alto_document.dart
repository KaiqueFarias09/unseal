import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../foundation/spatial/spatial_rect.dart';
import '../../foundation/spatial/spatial_unit.dart';
import '../../foundation/text/xml_encoding.dart';
import 'alto_document.dart';
import 'alto_exception.dart';

/// Input and structure bounds for the supported ALTO subset. Hostile or
/// oversized documents fail with [AltoException] before allocations.
const int _maxInputBytes = 32 * 1024 * 1024;
const int _maxPages = 1024;
const int _maxElementsPerPage = 65536;
const int _maxBlocksPerPage = 16384;
const int _maxLinesPerBlock = 16384;
const int _maxStringsPerLine = 4096;
const int _maxComposedDepth = 4;
const int _maxContentLength = 4096;

/// The ALTO namespaces the subset supports, mapped to their major
/// version.
const Map<String, int> _supportedNamespaces = <String, int>{
  'http://www.loc.gov/standards/alto/ns-v2#': 2,
  'http://www.loc.gov/standards/alto/ns-v3#': 3,
  'http://www.loc.gov/standards/alto/ns-v4#': 4,
};

/// Parses ALTO XML bytes into an [AltoDocument] under the declared
/// subset: namespaces v2, v3 and v4, the `Description` figures
/// (`MeasurementUnit`, OCR software, source image), and the positioned
/// content (`Page` > block kinds > `TextLine` > `String`/`SP`).
///
/// Coordinates keep the document's declared unit and the schema's
/// top-left origin. Elements outside the subset (glyph data, tags
/// collections, draft-only shapes) are ignored as data; elements the
/// subset requires but cannot serve — an unknown `MeasurementUnit`, a
/// page without usable dimensions, a `String` without `CONTENT` — fail
/// typed. Every traversal is bounded; hostile or oversized input fails
/// with [AltoException] instead of exhausting the caller.
AltoDocument parseAltoDocument(final Uint8List bytes) {
  if (bytes.length > _maxInputBytes) {
    throw const AltoException('ALTO input exceeds the 32 MiB limit.');
  }
  final XmlDocument document;
  try {
    document = XmlDocument.parse(decodeXmlText(bytes));
  } on XmlException {
    throw const AltoException('ALTO input is not well-formed XML.');
  }
  final root = document.rootElement;
  final version = _supportedNamespaces[root.name.namespaceUri];
  if (version == null) {
    throw AltoUnsupportedFeatureException(
      'ALTO root namespace ${root.name.namespaceUri ?? '(none)'} is outside '
      'the supported versions (ns-v2, ns-v3, ns-v4).',
    );
  }

  final description = _child(root, 'Description');
  final unit = _parseMeasurementUnit(description);
  final (softwareName, softwareVersion) = _parseSoftware(description);
  final sourceImageName = _parseSourceImage(description);

  final layout = _child(root, 'Layout');
  if (layout == null) {
    throw const AltoException('ALTO document has no Layout.');
  }
  final pages = <AltoPage>[];
  var pageCount = 0;
  for (final node in layout.childElements) {
    if (node.name.local != 'Page') continue;
    pageCount++;
    if (pageCount > _maxPages) {
      throw const AltoException('ALTO document exceeds the 1024-page limit.');
    }
    pages.add(_parsePage(node, pageCount));
  }
  if (pages.isEmpty) {
    throw const AltoException('ALTO Layout declares no Page.');
  }

  return AltoDocument(
    version: version,
    unit: unit,
    softwareName: softwareName,
    softwareVersion: softwareVersion,
    sourceImageName: sourceImageName,
    pages: pages,
  );
}

XmlElement? _child(final XmlElement parent, final String local) {
  for (final node in parent.childElements) {
    if (node.name.local == local) return node;
  }

  return null;
}

SpatialUnit _parseMeasurementUnit(final XmlElement? description) {
  final node = description == null ? null : _child(description, 'MeasurementUnit');
  if (node == null) {
    throw const AltoException('ALTO Description declares no MeasurementUnit.');
  }
  final value = node.innerText.trim();
  switch (value) {
    case 'pixel':
      return SpatialUnit.pixel;
    case 'mm10':
      return SpatialUnit.millimeter10;
    case 'inch1200':
      return SpatialUnit.inch1200;
    default:
      throw AltoUnsupportedFeatureException('ALTO MeasurementUnit "$value" is not supported.');
  }
}

(String, String?) _parseSoftware(final XmlElement? description) {
  if (description == null) return ('', null);
  for (final processing in description.childElements) {
    if (processing.name.local != 'OCRProcessing') continue;
    final step = _child(processing, 'ocrProcessingStep');
    final software = step == null ? null : _child(step, 'processingSoftware');
    if (software == null) continue;
    final name = _child(software, 'softwareName')?.innerText.trim() ?? '';
    final version = _child(software, 'softwareVersion')?.innerText.trim();

    return (name, (version == null || version.isEmpty) ? null : version);
  }

  return ('', null);
}

String? _parseSourceImage(final XmlElement? description) {
  if (description == null) return null;
  final info = _child(description, 'sourceImageInformation');
  if (info == null) return null;
  final fileName = _child(info, 'fileName')?.innerText.trim();

  return (fileName == null || fileName.isEmpty) ? null : fileName;
}

AltoPage _parsePage(final XmlElement node, final int position) {
  final width = _requireDimension(node, 'WIDTH', position);
  final height = _requireDimension(node, 'HEIGHT', position);
  final printSpace = _child(node, 'PrintSpace');
  final blocks = <AltoBlock>[];
  if (printSpace != null) {
    _parseBlocks(printSpace, blocks, position, depth: 0);
  }

  return AltoPage(
    id: node.getAttribute('ID'),
    width: width,
    height: height,
    printedImageNumber: _intAttribute(node, 'PHYSICAL_IMG_NR'),
    confidence: _confidenceAttribute(node, 'PC'),
    accuracy: _floatAttribute(node, 'ACCURACY'),
    quality: node.getAttribute('QUALITY'),
    blocks: blocks,
  );
}

void _parseBlocks(
  final XmlElement parent,
  final List<AltoBlock> into,
  final int page, {
  required final int depth,
}) {
  for (final node in parent.childElements) {
    final kind = switch (node.name.local) {
      'TextBlock' => AltoBlockKind.text,
      'ComposedBlock' => AltoBlockKind.composed,
      'Illustration' => AltoBlockKind.illustration,
      'GraphicalElement' => AltoBlockKind.graphicalElement,
      _ => null,
    };
    if (kind == null) continue;
    if (into.length >= _maxBlocksPerPage) {
      throw AltoException('ALTO page $page exceeds the block limit.');
    }
    final rect = _rectOf(node, page, 'block');
    final block = AltoBlock(
      kind: kind,
      id: node.getAttribute('ID'),
      rect: rect,
      rotation: _floatAttribute(node, 'ROTATION'),
      blockTags: node.getAttribute('TAGREFS')?.split(' ').where((t) => t.isNotEmpty).toList(),
      lines: kind == AltoBlockKind.text ? _parseLines(node, page, rect) : const <AltoLine>[],
      children: const <AltoBlock>[],
    );
    into.add(block);
    if (kind == AltoBlockKind.composed) {
      if (depth >= _maxComposedDepth) {
        throw AltoException('ALTO page $page exceeds the composed-block depth limit.');
      }
      final children = <AltoBlock>[];
      _parseBlocks(node, children, page, depth: depth + 1);
      into[into.length - 1] = AltoBlock(
        kind: block.kind,
        id: block.id,
        rect: block.rect,
        rotation: block.rotation,
        blockTags: block.blockTags,
        lines: block.lines,
        children: children,
      );
    }
  }
}

List<AltoLine> _parseLines(final XmlElement block, final int page, final SpatialRect blockRect) {
  final lines = <AltoLine>[];
  var budget = _maxElementsPerPage;
  for (final node in block.childElements) {
    if (node.name.local != 'TextLine') continue;
    if (lines.length >= _maxLinesPerBlock) {
      throw AltoException('ALTO page $page exceeds the text-line limit.');
    }
    if (budget-- <= 0) {
      throw AltoException('ALTO page $page exceeds the element budget.');
    }
    lines.add(
      AltoLine(
        id: node.getAttribute('ID'),
        rect: _rectOf(node, page, 'line', fallback: blockRect),
        confidence: _confidenceAttribute(node, 'WC'),
        strings: _parseStrings(node, page),
      ),
    );
  }

  return lines;
}

List<AltoString> _parseStrings(final XmlElement line, final int page) {
  final strings = <AltoString>[];
  for (final node in line.childElements) {
    switch (node.name.local) {
      case 'String':
        if (strings.length >= _maxStringsPerLine) {
          throw AltoException('ALTO page $page exceeds the string limit.');
        }
        final content = node.getAttribute('CONTENT');
        if (content == null) {
          throw AltoException('ALTO page $page holds a String without CONTENT.');
        }
        if (content.length > _maxContentLength) {
          throw AltoException('ALTO page $page holds a String beyond the content limit.');
        }
        strings.add(
          AltoString(
            id: node.getAttribute('ID'),
            rect: _rectOf(node, page, 'String'),
            content: content,
            confidence: _confidenceAttribute(node, 'WC'),
            characterConfidences: node.getAttribute('CC'),
            substitutionType: node.getAttribute('SUBS_TYPE'),
            substitutionContent: node.getAttribute('SUBS_CONTENT'),
          ),
        );
      case 'SP':
      case 'HYP':
      case 'Shape':
      case 'ALTERNATIVE':
      case 'Glyph':
        // Separators and extension elements carry no positioned words;
        // the subset ignores them.
        continue;
      default:
        continue;
    }
  }

  return strings;
}

SpatialRect _rectOf(
  final XmlElement node,
  final int page,
  final String what, {
  final SpatialRect? fallback,
}) {
  final x = _floatAttribute(node, 'HPOS');
  final y = _floatAttribute(node, 'VPOS');
  final width = _floatAttribute(node, 'WIDTH');
  final height = _floatAttribute(node, 'HEIGHT');
  if (x == null || y == null || width == null || height == null) {
    if (fallback != null) return fallback;
    throw AltoException('ALTO page $page holds a $what without complete coordinates.');
  }

  return SpatialRect(x: x, y: y, width: width, height: height);
}

double _requireDimension(final XmlElement node, final String name, final int position) {
  final value = _floatAttribute(node, name);
  if (value == null || value <= 0) {
    throw AltoException('ALTO page $position declares no usable $name.');
  }

  return value;
}

double? _floatAttribute(final XmlElement node, final String name) {
  final raw = node.getAttribute(name);
  if (raw == null) return null;
  final value = double.tryParse(raw);
  if (value == null) {
    throw AltoException('ALTO attribute $name="$raw" is not a number.');
  }

  return value;
}

double? _confidenceAttribute(final XmlElement node, final String name) {
  final value = _floatAttribute(node, name);
  if (value == null) return null;
  if (value < 0 || value > 1) {
    throw AltoException('ALTO attribute $name="$value" lies outside 0..1.');
  }

  return value;
}

int? _intAttribute(final XmlElement node, final String name) {
  final raw = node.getAttribute(name);
  if (raw == null) return null;

  return int.tryParse(raw);
}
