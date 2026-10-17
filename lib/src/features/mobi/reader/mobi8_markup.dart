import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../codec/mobi_base32.dart';
import '../codec/mobi_byte_search.dart';
import '../codec/mobi_text_codec.dart';
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

  final List<Mobi8Flow> _flows = <Mobi8Flow>[];

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
      _flows.add(classifyMobi8Flow(j, slice));
    }
  }

  Mobi8Assembly _expandMarkup() {
    // One shared finalizer produces every part's markup: the session
    // path calls the same class per part.
    final finalizer = Mobi8MarkupFinalizer(
      flows: _flows,
      resourceMap: resources.resourceMap,
      resolvePosFid: structure.resolvePosFid,
      linkedAids: structure.linkedAids,
    );
    // Resolve references inside the flows themselves, then inline
    // flows and image references into the markup.
    for (final flow in _flows) {
      flow.content = finalizer.rewriteFlowContent(flow.content);
    }

    final parts = <String>[
      for (final bytes in structure.partBytes)
        finalizer.finalizePart(partBytes: bytes, codec: header.codec),
    ];

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

/// One classified KF8 secondary flow: CSS or SVG, with its output
/// filename when it stands alone (inline flows carry `null` and inject
/// their content into the referencing parts).
final class Mobi8Flow {
  /// Creates a flow descriptor with its (link-rewritten) content.
  Mobi8Flow(this.number, this.kind, this.filename, this.content);

  /// The 1-based flow number from the FDST table.
  final int number;

  /// Either `css` or `svg`.
  final String kind;

  /// The output filename, or null for inline flows.
  final String? filename;

  /// The flow content: raw text for css, the stripped SVG document.
  String content;
}

/// Classifies one secondary flow's bytes the way the eager parse has
/// always done: an SVG document (with or without a standalone file),
/// an inline CDATA style block, or a standalone CSS file.
Mobi8Flow classifyMobi8Flow(final int number, final Uint8List flowBytes) {
  final asText = String.fromCharCodes(flowBytes);
  final padded = number.toString().padLeft(4, '0');

  final svgMatch = _svgOpenTagPattern.firstMatch(asText);
  if (svgMatch != null) {
    final stripped = asText.substring(svgMatch.start);
    final hasImage = _svgImagePattern.hasMatch(stripped);
    if (hasImage) {
      return Mobi8Flow(number, 'svg', null, stripped);
    }

    return Mobi8Flow(number, 'svg', 'svg$padded.svg', stripped);
  }
  if (asText.contains('[CDATA[')) {
    return Mobi8Flow(number, 'css', null, '<style type="text/css">\n$asText\n</style>\n');
  }

  return Mobi8Flow(number, 'css', 'flow$padded.css', asText);
}

/// Finalizes one rebuilt KF8 part into its output markup: resolves
/// `kindle:pos:fid` links, strips kindlegen aid attributes (keeping
/// linked aids as ids), rewrites flow and embed references, and
/// normalizes the document head. Both the eager assembler and the
/// progressive session route every part through this class, so the
/// two paths cannot drift.
final class Mobi8MarkupFinalizer {
  /// Creates a finalizer over classified flows and the embed map.
  Mobi8MarkupFinalizer({
    required this.flows,
    required this.resourceMap,
    required this.resolvePosFid,
    required this.linkedAids,
  });

  /// The classified secondary flows; contents must be link-rewritten
  /// before parts referencing them inline finalize.
  final List<Mobi8Flow> flows;

  /// One-based Kindle embed numbering to output resource name.
  final List<String?> resourceMap;

  /// Resolves one `kindle:pos:fid` reference to its part file and
  /// anchor id, or null when it points nowhere.
  final (String, String)? Function(int fid, int offset) resolvePosFid;

  /// Aid values discovered by link resolution; they survive as `id`.
  final Set<String> linkedAids;

  /// Produces one part's final markup string.
  String finalizePart({required final Uint8List partBytes, required final String codec}) {
    // 1. Resolve internal pos:fid links.
    var markup = decodeMobi8Part(partBytes, codec);
    markup = markup.replaceAllMapped(mobi8PosFidPattern, (final match) {
      final resolved = resolvePosFid(parseBase32(match.group(1)!), parseBase32(match.group(2)!));
      if (resolved == null) return '"#"';

      final (filename, idtag) = resolved;

      return '"$filename${idtag.isEmpty ? '' : '#$idtag'}"';
    });

    // 2. Strip kindlegen aid/cid attributes (keeping linked ones as id).
    markup = stripMobi8AidAttributes(markup, linkedAids);
    if (containsAsciiIgnoreCase(markup, 'data-amznpagebreak')) {
      markup = markup.replaceAllMapped(mobi8PageBreakPattern, (final match) {
        return '${match.group(1)} style="page-break-after:${match.group(2)}"${match.group(3)}';
      });
    }

    // 3./4. Inline flows and image references into the markup.
    markup = _insertFlows(markup);
    markup = _insertImages(markup);

    return _normalizePart(markup);
  }

  /// Rewrites `kindle:embed`/`kindle:flow` references inside one
  /// flow's content. Runs before parts finalize, so inline flows inject
  /// fully rewritten content.
  String rewriteFlowContent(final String content) {
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

  String? _embedHref(final String base32Number) {
    final index = parseBase32(base32Number);
    if (index < 1 || index > resourceMap.length) return null;

    return resourceMap[index - 1];
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

  Mobi8Flow? _flowByNumber(final int number) {
    for (final flow in flows) {
      if (flow.number == number) return flow;
    }

    return null;
  }
}

/// Decodes a rebuilt part with the header's text codec.
String decodeMobi8Part(final Uint8List partBytes, final String codec) =>
    decodeBytes(partBytes, codec);
