part of '../parse_txt_book.dart';

/// The result of turning one TXT-family entry into reader HTML.
final class _TxtRenderedDocument {
  /// Creates a rendered document.
  const _TxtRenderedDocument({required this.html, required this.headings});

  /// XHTML-ish HTML suitable for the library's text-file model.
  final String html;

  /// Headings found while rendering Markdown/Textile input.
  final List<_TxtHeading> headings;
}

/// A heading discovered in a TXT-family document.
final class _TxtHeading {
  /// Creates a heading description.
  const _TxtHeading({required this.level, required this.label, required this.id});

  /// The source heading level, from 1 through 6.
  final int level;

  /// Human-readable heading label.
  final String label;

  /// Anchor emitted into the rendered HTML.
  final String id;
}

/// Decodes a TXT-family payload using the library's BOM/declaration-aware
/// decoder. The decoder supports UTF-8, UTF-16 and the legacy single-byte
/// families already used by EPUB/FB2, and always replaces malformed input.
String _decodeTxtBytes(final List<int> bytes) => decodeXmlText(bytes);

/// Normalizes line endings and the control/whitespace noise commonly found
/// in text exports. At the format boundary, CRLF and CR become LF, trailing
/// line whitespace goes away, and excessive empty lines are bounded without
/// deleting paragraph boundaries.
String _normalizeTxtText(final String input) {
  final buffer = StringBuffer();
  for (final codeUnit in input.codeUnits) {
    // Remove ASCII controls that cannot be represented safely in XML/HTML;
    // retain tab, LF and CR because they carry layout information.
    if (codeUnit < 0x09 ||
        (codeUnit >= 0x0B && codeUnit <= 0x0C) ||
        (codeUnit >= 0x0E && codeUnit <= 0x1F)) {
      continue;
    }

    buffer.writeCharCode(codeUnit);
  }

  final lines = buffer
      .toString()
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((final line) => line.replaceFirst(RegExp(r'[ \t]+$'), ''))
      .toList();
  while (lines.length > 1 && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.length > 1 && lines.last.trim().isEmpty) {
    lines.removeLast();
  }

  var emptyRun = 0;
  final bounded = <String>[];
  for (final line in lines) {
    if (line.trim().isEmpty) {
      emptyRun++;
      if (emptyRun <= 4) bounded.add('');
    } else {
      emptyRun = 0;
      bounded.add(line);
    }
  }

  return bounded.join('\n');
}

/// Renders plain TXT, Markdown-like TXT, or Textile-like TXT into the common document model.
/// Markdown/Textile support is intentionally small and safe. It covers the constructs needed to
/// preserve headings and local image references in TXTZ without pretending to be a complete
/// Markdown implementation.
_TxtRenderedDocument _renderTxtDocument(
  final String input, {
  final String title = '',
  final String formatting = 'plain',
}) {
  final kind = formatting.toLowerCase().trim();
  if (kind == 'markdown') return _renderMarkdown(input, title);
  if (kind == 'textile') return _renderTextile(input, title);

  return _renderPlain(input, title);
}

_TxtRenderedDocument _renderPlain(final String input, final String title) {
  final normalized = _normalizeTxtText(input);
  final lines = normalized.isEmpty ? const <String>[] : normalized.split('\n');
  final body = _renderPlainBlocks(lines);

  return _TxtRenderedDocument(html: _htmlDocument(title, body), headings: const <_TxtHeading>[]);
}

String _renderPlainBlocks(final List<String> lines) {
  if (lines.isEmpty) return '';

  final blocks = <String>[];
  final current = <String>[];
  var emptyRun = 0;

  void flush() {
    if (current.isEmpty) return;
    blocks.add('<p>${current.map(_plainLine).join(' ')}</p>');
    current.clear();
  }

  for (final line in lines) {
    if (line.trim().isEmpty) {
      flush();
      emptyRun++;
      // This mirrors convert_basic's useful visual marker for a deliberate
      // extra blank paragraph while still avoiding unbounded empty output.
      if (emptyRun == 2) blocks.add('<p>&nbsp;</p>');

      continue;
    }
    emptyRun = 0;
    current.add(line);
  }
  flush();

  return blocks.join('\n');
}

String _plainLine(final String line) {
  final indent = RegExp(r'^(?: {2,}|\t+)(?=.)').firstMatch(line);
  final leading = indent == null ? '' : '&nbsp;' * 4;
  final content = indent == null ? line : line.substring(indent.end);
  final condensed = content.replaceAll(RegExp(r' {2,}'), ' ');

  return leading + _escapeHtml(condensed);
}

_TxtRenderedDocument _renderMarkdown(final String input, final String title) {
  final normalized = _normalizeTxtText(input);
  final lines = normalized.isEmpty ? const <String>[] : normalized.split('\n');
  final headings = <_TxtHeading>[];
  final blocks = <String>[];
  final paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add('<p>${paragraph.map(_markdownInline).join(' ')}</p>');
    paragraph.clear();
  }

  for (final line in lines) {
    if (line.trim().isEmpty) {
      flushParagraph();

      continue;
    }

    final heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$').firstMatch(line);
    if (heading != null) {
      flushParagraph();
      final level = heading.group(1)!.length;
      final label = heading.group(2)!.trim();
      final id = _headingId(label, headings.length);
      headings.add(_TxtHeading(level: level, label: _stripMarkdown(label), id: id));
      blocks.add('<h$level id="$id">${_markdownInline(label)}</h$level>');

      continue;
    }

    paragraph.add(line);
  }
  flushParagraph();

  return _TxtRenderedDocument(html: _htmlDocument(title, blocks.join('\n')), headings: headings);
}

_TxtRenderedDocument _renderTextile(final String input, final String title) {
  final normalized = _normalizeTxtText(input);
  final lines = normalized.isEmpty ? const <String>[] : normalized.split('\n');
  final headings = <_TxtHeading>[];
  final blocks = <String>[];
  final paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add('<p>${paragraph.map(_textileInline).join(' ')}</p>');
    paragraph.clear();
  }

  for (final line in lines) {
    if (line.trim().isEmpty) {
      flushParagraph();

      continue;
    }

    final heading = RegExp(r'^h([1-6])\.\s+(.+)$').firstMatch(line.trim());
    if (heading != null) {
      flushParagraph();
      final level = int.parse(heading.group(1)!);
      final label = heading.group(2)!.trim();
      final id = _headingId(label, headings.length);
      headings.add(_TxtHeading(level: level, label: _stripTextile(label), id: id));
      blocks.add('<h$level id="$id">${_textileInline(label)}</h$level>');

      continue;
    }

    final paragraphLine = RegExp(r'^p\.\s+(.+)$').firstMatch(line.trim());
    paragraph.add(paragraphLine?.group(1) ?? line);
  }
  flushParagraph();

  return _TxtRenderedDocument(html: _htmlDocument(title, blocks.join('\n')), headings: headings);
}

String _markdownInline(final String input) {
  final placeholders = <String, String>{};
  var value = input;
  var placeholderIndex = 0;
  value = value.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'), (final match) {
    final source = match.group(2)!.trim();
    if (!_isLocalReference(source)) return match.group(0)!;

    final token = '__ELIVRE_IMAGE_${placeholderIndex++}__';
    placeholders[token] =
        '<img src="${_escapeHtml(source)}" alt="${_escapeHtml(match.group(1)!)}">';

    return token;
  });
  value = value.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (final match) {
    final href = match.group(2)!.trim();
    if (!_isSafeLink(href)) return match.group(0)!;

    final token = '__ELIVRE_LINK_${placeholderIndex++}__';
    placeholders[token] = '<a href="${_escapeHtml(href)}">${_escapeHtml(match.group(1)!)}</a>';

    return token;
  });

  var escaped = _escapeHtml(value);
  escaped = escaped.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (final match) {
    return '<strong>${match.group(1)}</strong>';
  });
  escaped = escaped.replaceAllMapped(RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)'), (final match) {
    return '<em>${match.group(1)}</em>';
  });
  for (final entry in placeholders.entries) {
    escaped = escaped.replaceAll(entry.key, entry.value);
  }

  return escaped;
}

String _textileInline(final String input) {
  final placeholders = <String, String>{};
  var value = input;
  var placeholderIndex = 0;
  value = value.replaceAllMapped(RegExp(r'!([^\s(!]+)(?:\(([^)]*)\))?!'), (final match) {
    final source = match.group(1)!;
    if (!_isLocalReference(source)) return match.group(0)!;

    final token = '__ELIVRE_IMAGE_${placeholderIndex++}__';
    placeholders[token] =
        '<img src="${_escapeHtml(source)}" alt="${_escapeHtml(match.group(2) ?? '')}">';

    return token;
  });

  var escaped = _escapeHtml(value);
  escaped = escaped.replaceAllMapped(RegExp(r'\*([^*]+)\*'), (final match) {
    return '<strong>${match.group(1)}</strong>';
  });
  escaped = escaped.replaceAllMapped(RegExp(r'_([^_]+)_'), (final match) {
    return '<em>${match.group(1)}</em>';
  });
  for (final entry in placeholders.entries) {
    escaped = escaped.replaceAll(entry.key, entry.value);
  }

  return escaped;
}

String _htmlDocument(final String title, final String body) {
  return '<!DOCTYPE html><html><head><meta charset="utf-8"><title>'
      '${_escapeHtml(title)}</title></head><body>$body</body></html>';
}

String _headingId(final String label, final int index) {
  final slug = _stripMarkup(
    label,
  ).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  return slug.isEmpty ? 'heading-${index + 1}' : '$slug-${index + 1}';
}

String _stripMarkdown(final String value) {
  return value
      .replaceAll(RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'), r'$1')
      .replaceAll(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), r'$1')
      .replaceAll(RegExp(r'[*_`]'), '');
}

String _stripTextile(final String value) => value.replaceAll(RegExp(r'[!*_]'), '');

String _stripMarkup(final String value) => _stripTextile(_stripMarkdown(value));

bool _isLocalReference(final String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.startsWith('/') || trimmed.startsWith('\\')) return false;
  if (trimmed.contains(':') || trimmed.contains('\u0000')) return false;

  return !trimmed.split('/').contains('..');
}

bool _isSafeLink(final String value) {
  final lower = value.toLowerCase().trim();

  return !(lower.startsWith('javascript:') || lower.startsWith('data:'));
}

String _escapeHtml(final String value) {
  return const convert.HtmlEscape().convert(value);
}

/// Extracts the lightweight TXT metadata convention: title, two blank lines,
/// then author. A filename stem is a useful fallback when the caller has one,
/// but is intentionally optional so byte-only parsing stays deterministic.
({String? title, List<String> authors}) _txtHeaderMetadata(
  final String input, {
  final String? sourceName,
}) {
  final lines = _normalizeTxtText(input).split('\n');
  String? title;
  List<String> authors = const <String>[];
  if (lines.length >= 4 &&
      lines[0].trim().isNotEmpty &&
      lines[1].trim().isEmpty &&
      lines[2].trim().isEmpty &&
      lines[3].trim().isNotEmpty) {
    title = lines[0].trim();
    authors = lines[3]
        .split(',')
        .map((final author) => author.trim())
        .where((final author) => author.isNotEmpty)
        .toList();
  }

  if (title == null && sourceName != null) {
    final name = sourceName.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    if (stem.trim().isNotEmpty) title = stem.trim();
  }

  return (title: title, authors: authors);
}

/// Returns the bounded prefix needed for metadata-only TXT reads.
Uint8List _metadataTxtPrefix(final Uint8List bytes, [final int limit = 64 * 1024]) {
  if (bytes.length <= limit) return bytes;

  var length = limit;
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    length -= length.isOdd ? 1 : 0;
  }
  if (bytes.length >= 4 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0 && bytes[3] == 0) ||
          (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xFE && bytes[3] == 0xFF))) {
    length -= length % 4;
  }

  return Uint8List.sublistView(bytes, 0, length);
}
