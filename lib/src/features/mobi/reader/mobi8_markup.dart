import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../codec/mobi_base32.dart';
import '../codec/mobi_byte_search.dart';
import '../header/mobi_header.dart';
import 'mobi8_resources.dart';
import 'mobi8_structure.dart';

final RegExp _flowImageTagPattern = RegExp(
  r'(<(?:img|image|svg:image)\b[^>]*>)',
  caseSensitive: false,
);
final RegExp _kindleEmbedQuotedPattern = RegExp(
  '''['"]kindle:embed:([0-9A-V]+)[^"']*['"]''',
  caseSensitive: false,
);
final RegExp _cssUrlPattern = RegExp(r'url\((.*?)\)', caseSensitive: false, dotAll: true);
final RegExp _kindleEmbedMimePattern = RegExp(
  r'''kindle:embed:([0-9A-V]+)\?mime=image/[^\)]*''',
  caseSensitive: false,
);
final RegExp _kindleEmbedPattern = RegExp('kindle:embed:([0-9A-V]+)', caseSensitive: false);
final RegExp _kindleFlowCssPattern = RegExp(
  r'''kindle:flow:([0-9A-V]+)\?mime=text/css[^\)]*''',
  caseSensitive: false,
);
final RegExp _anyTagPattern = RegExp('(<[^>]*>)');
final RegExp _flowRefPattern = RegExp(
  r'''['"]kindle:flow:([0-9A-V]+)\?mime=([^'"]+)['"]''',
  caseSensitive: false,
);
final RegExp _imgTagPattern = RegExp(r'(<(?:img|image)\b[^>]*>)', caseSensitive: false);
final RegExp _kindleEmbedWrappedPattern = RegExp(
  '''[('"]kindle:embed:([0-9A-V]+)[^'")]*[)'"]''',
  caseSensitive: false,
);
final RegExp _styledTagPattern = RegExp(
  r'(<[a-zA-Z0-9]+\s[^>]*style\s*=\s*[^>]*>)',
  caseSensitive: false,
);
final RegExp _xmlDeclarationPattern = RegExp(r'<\?xml[^>]*>');
final RegExp _svgOpenTagPattern = RegExp('<svg[^>]*>', caseSensitive: false);
final RegExp _svgImagePattern = RegExp('<(?:svg:)?image[^>]*>', caseSensitive: false);

/// Expands KF8 flows, resource references, and Kindle-specific links.
final class Mobi8MarkupAssembler {
  /// Creates a markup assembler over decoded KF8 capabilities.
  Mobi8MarkupAssembler({required this.header, required this.structure, required this.resources});

  /// KF8 header containing cover metadata.
  final MobiHeader header;

  /// Rebuilt skeletons and positional link resolver.
  final Mobi8Structure structure;

  /// Decoded resource files and embed map.
  final Mobi8Resources resources;

  final List<_Mobi8Flow> _flows = <_Mobi8Flow>[];

  /// Produces the complete KF8 assembly.
  Mobi8Assembly assemble() {
    _flows.clear();
    _classifyFlows();

    return _expandMarkup();
  }

  void _classifyFlows() {
    final rawText = structure.rawText;
    final flowSlices = structure.flowTable.isEmpty
        ? <(int, int)>[(0, rawText.length)]
        : structure.flowTable;
    for (var j = 1; j < flowSlices.length; j++) {
      final (start, end) = flowSlices[j];
      final slice = Uint8List.sublistView(
        rawText,
        start,
        end > rawText.length ? rawText.length : end,
      );
      final asText = String.fromCharCodes(slice);
      final number = j.toString().padLeft(4, '0');

      final svgMatch = _svgOpenTagPattern.firstMatch(asText);
      if (svgMatch != null) {
        final stripped = asText.substring(svgMatch.start);
        final hasImage = _svgImagePattern.hasMatch(stripped);
        if (hasImage) {
          _flows.add(_Mobi8Flow(j, 'svg', null, stripped));
        } else {
          _flows.add(_Mobi8Flow(j, 'svg', 'svg$number.svg', stripped));
        }
      } else if (asText.contains('[CDATA[')) {
        _flows.add(_Mobi8Flow(j, 'css', null, '<style type="text/css">\n$asText\n</style>\n'));
      } else {
        _flows.add(_Mobi8Flow(j, 'css', 'flow$number.css', asText));
      }
    }
  }

  String? _embedHref(final String base32Number) {
    final index = parseBase32(base32Number);
    if (index < 1 || index > resources.resourceMap.length) return null;

    return resources.resourceMap[index - 1];
  }

  Mobi8Assembly _expandMarkup() {
    // 1. Resolve internal pos:fid links, then decode to strings.
    var parts = <String>[
      for (final bytes in structure.partBytes) structure.updateInternalLinks(bytes),
    ];

    // 2. Strip kindlegen aid/cid attributes (keeping linked ones as id).
    parts = parts.map(structure.removeKindleAids).toList();

    // 3. Resolve references inside the flows themselves.
    for (final flow in _flows) {
      flow.content = _updateFlowLinks(flow.content);
    }

    // 4. Inline flows and image references into the markup.
    for (var i = 0; i < parts.length; i++) {
      parts[i] = _insertFlows(parts[i]);
      parts[i] = _insertImages(parts[i]);
      parts[i] = _normalizePart(parts[i]);
    }

    final html = <TextFile>[];
    for (var i = 0; i < parts.length; i++) {
      final name = structure.partName(i);
      html.add(TextFile(name: name, type: 'html', path: name, content: parts[i]));
    }

    final css = <TextFile>[];
    final svgImages = <BinaryFile>[];
    for (final flow in _flows) {
      if (flow.filename == null) continue;

      if (flow.kind == 'css') {
        css.add(
          TextFile(name: flow.filename!, type: 'css', path: flow.filename!, content: flow.content),
        );
      } else {
        svgImages.add(
          BinaryFile(
            content: Uint8List.fromList(flow.content.codeUnits),
            name: flow.filename!,
            type: 'svg',
            path: flow.filename!,
          ),
        );
      }
    }

    String? coverName;
    final coverOffset = header.exth?.coverOffset;
    if (coverOffset != null && coverOffset < resources.resourceMap.length) {
      coverName = resources.resourceMap[coverOffset];
    }

    return Mobi8Assembly(
      html,
      css,
      [...resources.images, ...svgImages],
      List<BinaryFile>.from(resources.fonts),
      structure.buildToc(),
      resources.resourceMap,
      coverName,
    );
  }

  _Mobi8Flow? _flowByNumber(final int number) {
    for (final flow in _flows) {
      if (flow.number == number) return flow;
    }

    return null;
  }

  String _insertFlows(final String part) {
    if (!containsAsciiIgnoreCase(part, 'kindle:flow')) return part;

    return part.replaceAllMapped(_anyTagPattern, (final tagMatch) {
      final tag = tagMatch.group(1)!;
      final match = _flowRefPattern.firstMatch(tag);
      if (match == null) return tag;

      final target = _flowByNumber(parseBase32(match.group(1)!));
      if (target == null) return tag;
      if (target.filename == null) return target.content;

      return tag.replaceFirst(_flowRefPattern, '"${target.filename}"');
    });
  }

  String _insertImages(final String part) {
    if (!containsAsciiIgnoreCase(part, 'kindle:embed')) return part;

    var result = part.replaceAllMapped(_imgTagPattern, (final tagMatch) {
      final tag = tagMatch.group(1)!;

      return tag.replaceFirstMapped(_kindleEmbedWrappedPattern, (final match) {
        final href = _embedHref(match.group(1)!);

        return href == null ? match.group(0)! : '"$href"';
      });
    });
    result = result.replaceAllMapped(_styledTagPattern, (final tagMatch) {
      final tag = tagMatch.group(1)!;
      if (!tag.contains('kindle:embed')) return tag;

      return tag.replaceAllMapped(_kindleEmbedWrappedPattern, (final match) {
        final href = _embedHref(match.group(1)!);

        return href == null ? match.group(0)! : '"$href"';
      });
    });

    return result;
  }

  String _normalizePart(final String part) {
    var result = part.replaceAll(_xmlDeclarationPattern, '');
    result = result.replaceAll('\uFEFF', '');
    if (!result.contains('charset')) {
      result = result.replaceFirst('<head>', '<head><meta charset="utf-8"/>');
    }

    return result;
  }

  String _updateFlowLinks(final String content) {
    var result = content.replaceAllMapped(_flowImageTagPattern, (final tagMatch) {
      final tag = tagMatch.group(1)!;

      return tag.replaceFirstMapped(_kindleEmbedQuotedPattern, (final match) {
        return '"${_embedHref(match.group(1)!) ?? ''}"';
      });
    });
    result = result.replaceAllMapped(_cssUrlPattern, (final urlMatch) {
      var inner = urlMatch.group(1)!;
      inner = inner.replaceAllMapped(_kindleEmbedMimePattern, (final match) {
        return _embedHref(match.group(1)!) ?? match.group(0)!;
      });
      inner = inner.replaceAllMapped(
        _kindleEmbedPattern,
        (final match) => _embedHref(match.group(1)!) ?? match.group(0)!,
      );
      inner = inner.replaceAllMapped(_kindleFlowCssPattern, (final match) {
        final target = _flowByNumber(parseBase32(match.group(1)!));

        return target?.filename ?? match.group(0)!;
      });

      return 'url($inner)';
    });

    return result;
  }
}

/// Fully assembled KF8 (AZW3) content.
class Mobi8Assembly {
  /// Creates the assembled XHTML, resources, navigation, and cover metadata.
  const Mobi8Assembly(
    this.html,
    this.css,
    this.images,
    this.fonts,
    this.navigation,
    this.resourceMap,
    this.coverName,
  );

  /// Rebuilt XHTML files.
  final List<TextFile> html;

  /// Standalone CSS files.
  final List<TextFile> css;

  /// Images (incl. standalone SVG flows).
  final List<BinaryFile> images;

  /// Fonts.
  final List<BinaryFile> fonts;

  /// TOC from the NCX index.
  final Navigation navigation;

  /// Resource index (1-based embed numbering) to file name.
  final List<String?> resourceMap;

  /// The cover resource name, when resolved.
  final String? coverName;
}

final class _Mobi8Flow {
  _Mobi8Flow(this.number, this.kind, this.filename, this.content);

  final int number;
  final String kind;
  final String? filename;
  String content;
}
