import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../../foundation/entities/entities.dart';
import '../../foundation/text/canonical_document_text.dart';

/// How far behind the verified document text may sit from the DOM walk's offset before the drift
/// repair gives up.
const int _verificationSlack = 64;

/// Cap on the anchor snippet used for drift verification.
const int _snippetLength = 256;
const String _replacementCharacter = '\uFFFD';
const Set<String> _xmlPredefinedEntities = <String>{'lt', 'gt', 'amp', 'quot', 'apos'};

final RegExp _fileposPattern = RegExp(r'^filepos(\d+)$');
final RegExp _namedEntityPattern = RegExp(r'&([a-zA-Z][a-zA-Z0-9]{1,31});');
final RegExp _numericEntityPattern = RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+);');

/// Per-book caches. A Dart extension cannot add fields to a Book, so they hang off the book through
/// Expando objects (the same technique the CFI resolver uses); entries die with their book instance.
final Expando<Map<String, TextFile?>> _htmlFileCache = Expando<Map<String, TextFile?>>();
final Expando<Map<String, int?>> _sectionIndexCache = Expando<Map<String, int?>>();
final Expando<Map<String, int?>> _anchorOffsetCache = Expando<Map<String, int?>>();
final Expando<Map<String, int?>> _markerSectionCache = Expando<Map<String, int?>>();

/// The parsed shape of a raw `NavPoint.content` string.
///
/// Table-of-contents entries address a position in different ways per format: an EPUB href
/// (`chapter.xhtml`, `chapter.xhtml#frag`, percent-encoded), a MOBI `fileposNNN` link (with or
/// without the `#`), an FB2 source (`index.html#section_1`, or a bare `#id`). [_parseNavContent]
/// splits those shapes apart without interpreting them; `NavResolution.navTargetOf` resolves them
/// against a [Book].
final class _ParsedNavContent {
  const _ParsedNavContent({this.path, this.fragment, this.filepos});

  final String? path;
  final String? fragment;
  final int? filepos;
}

_ParsedNavContent _parseNavContent(final String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const _ParsedNavContent();

  final hash = trimmed.indexOf('#');
  if (hash < 0) {
    final filepos = _fileposNumber(trimmed);
    if (filepos != null) return _ParsedNavContent(filepos: filepos);

    return _ParsedNavContent(path: trimmed);
  }

  final path = hash == 0 ? null : trimmed.substring(0, hash);
  final after = trimmed.substring(hash + 1);
  if (after.isEmpty) return _ParsedNavContent(path: path);

  return _ParsedNavContent(path: path, fragment: after, filepos: _fileposNumber(after));
}

/// A table-of-contents entry resolved to a position in a book's reading order.
///
/// `sectionIndex` addresses `Book.readingOrder`; `charOffset` addresses the same `documentText`
/// space as `BookSearch.search` and the CFI resolver.
final class NavTarget {
  /// Creates a [NavTarget].
  const NavTarget({required this.sectionIndex, this.charOffset, this.anchorId});

  /// Index of the resolved section inside the book's reading order.
  final int sectionIndex;

  /// Character offset of the entry's anchor inside the section's document text, or `null` when the
  /// entry carries no anchor, the anchor does not resolve, or the target is a MOBI `filepos` (a
  /// byte position of the MOBI stream, not a document text offset).
  final int? charOffset;

  /// The anchor id of the entry's fragment, when it has one and it is not a MOBI `filepos`
  /// position.
  final String? anchorId;

  @override
  String toString() => 'NavTarget(section: $sectionIndex, offset: $charOffset, anchor: $anchorId)';
}

/// Resolution of `NavPoint.content` strings against a [Book].
///
/// EPUB hrefs match reading-order sections by exact path or by path suffix (an NCX href is relative
/// to its own directory, so `xhtml/halftitle.xhtml` matches the spine item
/// `EPUB/xhtml/halftitle.xhtml`); percent-encoded hrefs are decoded before matching. Fragments
/// resolve to a character offset through the anchor's element, using the technique of a viewer's
/// `getElementById` + text-node walk. Bare fragments default to section 0; MOBI `filepos` targets
/// map to the section carrying the matching `id="fileposN"` anchor (section 0 when none does).
extension NavResolution on Book {
  /// Resolves [point]'s raw content string to a [NavTarget], or `null` when nothing in the reading
  /// order matches (unknown path, empty book).
  NavTarget? navTargetOf(final NavPoint point) {
    final sections = readingOrder;
    if (sections.isEmpty) return null;

    final parsed = _parseNavContent(point.content);
    if (parsed.path == null && parsed.filepos != null) {
      return NavTarget(sectionIndex: _sectionOfMarker('filepos${parsed.filepos}'));
    }

    var sectionIndex = 0;
    final path = parsed.path;
    if (path != null) {
      final index = _sectionIndexOf(path);
      if (index == null) return null;

      sectionIndex = index;
    }

    final fragment = parsed.fragment == null ? null : _decodeHrefComponent(parsed.fragment!);
    if (fragment == null) return NavTarget(sectionIndex: sectionIndex);

    final file = _htmlFileOf(sections[sectionIndex].name);
    if (file == null) return NavTarget(sectionIndex: sectionIndex, anchorId: fragment);

    return NavTarget(
      sectionIndex: sectionIndex,
      charOffset: _anchorOffsetOf(file, fragment),
      anchorId: fragment,
    );
  }

  /// Reading-order index of the section whose name is [rawPath] (exactly, percent-decoded, or as a
  /// path-suffix), or `null`.
  int? _sectionIndexOf(final String rawPath) {
    return (_sectionIndexCache[this] ??= <String, int?>{}).putIfAbsent(
      rawPath,
      () => _matchSection(rawPath),
    );
  }

  int? _matchSection(final String rawPath) {
    final sections = readingOrder;
    final path = _decodeHrefComponent(rawPath);
    for (var i = 0; i < sections.length; i++) {
      final name = sections[i].name;
      if (name == rawPath || name == path) return i;
    }

    final lower = path.toLowerCase();
    for (var i = 0; i < sections.length; i++) {
      final name = sections[i].name.toLowerCase();
      if (name == lower || name.endsWith('/$lower')) return i;
    }

    return null;
  }

  /// Reading-order index of the section whose HTML carries [marker] as an `id` or named anchor, or
  /// 0 when no section does.
  int _sectionOfMarker(final String marker) {
    return (_markerSectionCache[this] ??= <String, int?>{}).putIfAbsent(
          marker,
          () => _findMarkerSection(marker),
        ) ??
        0;
  }

  int? _findMarkerSection(final String marker) {
    final sections = readingOrder;
    for (var i = 0; i < sections.length; i++) {
      final file = _htmlFileOf(sections[i].name);
      if (file == null) continue;

      final body = html.parse(_alignedSource(file.content)).body;
      if (body != null &&
          (_findById(body, marker) != null || _findNamedAnchor(body, marker) != null)) {
        return i;
      }
    }

    return null;
  }

  /// The `files.html` entry of [name], or `null`.
  TextFile? _htmlFileOf(final String name) {
    return (_htmlFileCache[this] ??= <String, TextFile?>{}).putIfAbsent(
      name,
      () => _findHtmlFile(name),
    );
  }

  TextFile? _findHtmlFile(final String name) {
    for (final file in files.html) {
      if (file.path == name) return file;
    }

    return null;
  }

  /// Character offset of the anchor [id] inside [file]'s document text, or `null` when the anchor
  /// does not exist.
  int? _anchorOffsetOf(final TextFile file, final String id) {
    return (_anchorOffsetCache[this] ??= <String, int?>{}).putIfAbsent(
      '${file.path}#$id',
      () => _resolveAnchorOffset(file, id),
    );
  }

  int? _resolveAnchorOffset(final TextFile file, final String id) {
    final document = html.parse(_alignedSource(file.content));
    final body = document.body;
    if (body == null) return null;

    final target = _findById(body, id) ?? _findNamedAnchor(body, id);
    if (target == null) return null;

    final (offset, snippet) = _textPositionOf(body, target);
    if (snippet.isEmpty) return offset;
    // The DOM walk computes lengths on the tokenizer's text; verify against the canonical document
    // text and repair any residual drift by locating the anchor's first text nearby.
    final canonical = documentTextOf(file);
    if (canonical.startsWith(snippet, offset)) return offset;

    final from = offset - _verificationSlack < 0 ? 0 : offset - _verificationSlack;
    final found = canonical.indexOf(snippet, from);

    return found < 0 ? null : found;
  }
}

/// Resolves every table-of-contents entry of [book], flattened in reading order, to its
/// [NavTarget].
///
/// Entries that resolve nowhere stay `null` in the list, so positions correspond to a pre-order
/// walk of `book.navigation.navPoints`.
List<NavTarget?> resolveNavigation(final Book book) {
  final targets = <NavTarget?>[];
  void visit(final List<NavPoint> points) {
    for (final point in points) {
      targets.add(book.navTargetOf(point));
      visit(point.subNavPoints);
    }
  }

  visit(book.navigation.navPoints);

  return targets;
}

/// Decoded form of an href path: percent-decoded when encoded, otherwise as written.
String _decodeHrefComponent(final String component) {
  if (!component.contains('%')) return component;

  try {
    return Uri.decodeComponent(component);
  } on FormatException {
    return component;
  }
}

/// The source handed to the HTML tokenizer, entity-aligned with the `documentText` space: named
/// entities are pre-decoded exactly like [decodeEntity] decodes them (the five XML predefined ones
/// stay escaped for the tokenizer, unknown names are re-escaped so they stay literal), and numeric
/// C1 references are pinned to U+FFFD.
String _alignedSource(final String content) {
  final source = content.replaceAllMapped(_namedEntityPattern, (final match) {
    final name = match.group(1)!;
    if (_xmlPredefinedEntities.contains(name)) return match.group(0)!;

    return decodeEntity(name) ?? '&amp;$name;';
  });

  return source.replaceAllMapped(_numericEntityPattern, (final match) {
    final decoded = decodeEntity(match.group(1)!);

    return decoded == _replacementCharacter ? _replacementCharacter : match.group(0)!;
  });
}

/// The element of [root]'s subtree whose `id` attribute is [id], in document order, or `null`.
dom.Element? _findById(final dom.Element root, final String id) {
  return _findElement(root, (final element) => element.id == id);
}

/// The `<a>` element of [root]'s subtree whose `name` attribute is [name] (legacy `<a name>`
/// anchors), in document order, or `null`.
dom.Element? _findNamedAnchor(final dom.Element root, final String name) {
  return _findElement(root, (final element) {
    return element.localName?.toLowerCase() == 'a' && element.attributes['name'] == name;
  });
}

dom.Element? _findElement(
  final dom.Element root,
  final bool Function(dom.Element element) matches,
) {
  if (matches(root)) return root;

  for (final child in root.children) {
    final found = _findElement(child, matches);
    if (found != null) return found;
  }

  return null;
}

/// The `(offset, snippet)` of `target`'s first visible text: `offset` is the document position
/// where it starts (text preceding it inside `root`'s subtree, skipping `script`/`style` and the
/// whitespace around the anchor), `snippet` that text's leading content, capped. Without any
/// visible text inside the target (a bare `<a name>` anchor), `offset` is the target's entry
/// boundary and `snippet` is empty.
(int, String) _textPositionOf(final dom.Element root, final dom.Element target) {
  return _TextPositionFinder(target).find(root);
}

final class _TextPositionFinder {
  _TextPositionFinder(this.target);

  final dom.Element target;
  var _consumed = 0;
  var _entry = 0;
  var _snippet = '';

  (int, String) find(final dom.Element root) {
    _visit(root, insideTarget: false);

    return (_snippet.isEmpty ? _entry : _consumed, _snippet);
  }

  bool _visit(final dom.Node node, {required final bool insideTarget}) {
    if (node is dom.Element) {
      final name = node.localName?.toLowerCase() ?? '';
      if (name == 'script' || name == 'style') return false;

      final isInsideTarget = insideTarget || identical(node, target);
      if (identical(node, target)) _entry = _consumed;

      for (final child in node.nodes) {
        if (_visit(child, insideTarget: isInsideTarget)) return true;
      }

      return false;
    }
    if (node is dom.Text) {
      if (insideTarget) {
        if (node.data.trim().isEmpty) return false;

        _snippet = node.data.length > _snippetLength
            ? node.data.substring(0, _snippetLength)
            : node.data;

        return true;
      }

      _consumed += node.data.length;
    }

    return false;
  }
}

/// The numeric value of a `fileposNNN` string, or `null`.
int? _fileposNumber(final String value) {
  final match = _fileposPattern.firstMatch(value);
  if (match == null) return null;

  return int.tryParse(match.group(1)!);
}
