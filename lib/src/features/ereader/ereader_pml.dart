import 'dart:convert';

import '../../foundation/exceptions/unseal_exception.dart';

/// A bounded, reading-oriented projection of Palm Markup Language.
///
/// Only local fragments and image names supplied by the PDB image table become
/// links. Other PML controls are ignored rather than emitted as unsafe HTML.
EreaderPmlResult renderEreaderPml(
  final String pml, {
  required final Map<String, String> imagePaths,
}) {
  const escape = HtmlEscape(HtmlEscapeMode.element);
  final html = StringBuffer('<!doctype html><html><head><meta charset="utf-8"></head><body>');
  final headings = <EreaderPmlHeading>[];
  final active = <String>[];
  final headingText = StringBuffer();
  String? headingCode;
  String? headingId;
  var nextHeading = 1;
  var nextAnchor = 1;

  String tag(final String code) => switch (code) {
    'B' || 'b' => 'strong',
    'i' || 'I' => 'em',
    'u' => 'u',
    'o' => 's',
    'Sp' => 'sup',
    'Sb' => 'sub',
    _ => 'span',
  };

  void toggle(final String code) {
    final normalized = code == 'b' ? 'B' : (code == 'I' ? 'i' : code);
    final index = active.indexOf(normalized);
    if (index < 0) {
      active.add(normalized);
      html.write('<${tag(normalized)}>');
      return;
    }
    final reopen = active.sublist(index + 1);
    for (var i = active.length - 1; i >= index; i--) {
      html.write('</${tag(active[i])}>');
    }
    active.removeRange(index, active.length);
    for (final style in reopen) {
      active.add(style);
      html.write('<${tag(style)}>');
    }
  }

  void finishHeading() {
    if (headingCode == null) return;
    final level = headingCode == 'x' ? 1 : 2 + int.parse(headingCode!.substring(1));
    html.write('</h$level>');
    final label = headingText.toString().trim();
    if (label.isNotEmpty) headings.add(EreaderPmlHeading(headingId!, label));
    headingText.clear();
    headingCode = null;
    headingId = null;
  }

  for (var cursor = 0; cursor < pml.length;) {
    if ((cursor & 4095) == 0 && html.length > 2 * 64 * 1024 * 1024) {
      throw const InvalidBookException('Rendered eReader HTML exceeds the 128 MiB limit.');
    }
    final character = pml[cursor++];
    if (character != r'\' || cursor >= pml.length) {
      if (character == '\n') {
        html.write('<br/>');
        if (headingCode != null) headingText.write(' ');
      } else if (character == '\r') {
        // CRLF is handled by its LF; lone CR is a line break.
        if (cursor >= pml.length || pml[cursor] != '\n') html.write('<br/>');
      } else {
        html.write(escape.convert(character));
        if (headingCode != null) headingText.write(character);
      }
      continue;
    }

    var code = pml[cursor++];
    if ((code == 'X' || code == 'C') && cursor < pml.length && '01234'.contains(pml[cursor])) {
      code += pml[cursor++];
    } else if (code == 'S' && cursor < pml.length && (pml[cursor] == 'p' || pml[cursor] == 'b')) {
      code += pml[cursor++];
    } else if ((code == 'F' && cursor < pml.length && pml[cursor] == 'n') ||
        (code == 'S' && cursor < pml.length && pml[cursor] == 'd')) {
      code += pml[cursor++];
    }

    String? argument;
    if (cursor < pml.length && pml[cursor] == '=') {
      cursor++;
      if (cursor < pml.length && pml[cursor] == '"') {
        final start = ++cursor;
        while (cursor < pml.length && pml[cursor] != '"') {
          cursor++;
        }
        if (cursor >= pml.length) {
          throw const InvalidBookException('Unterminated eReader PML argument.');
        }
        argument = pml.substring(start, cursor++);
      }
    }

    if (code == r'\') {
      html.write(r'\');
    } else if (code == 'n') {
      html.write('<br/>');
    } else if (code == 't') {
      html.write('&#9;');
    } else if (const <String>{'B', 'b', 'i', 'I', 'u', 'o', 'Sp', 'Sb'}.contains(code)) {
      toggle(code);
    } else if (code == 'x' || RegExp(r'^X[0-4]$').hasMatch(code)) {
      if (headingCode == code) {
        finishHeading();
      } else if (headingCode == null) {
        headingCode = code;
        headingId = 'pml-heading-${nextHeading++}';
        final level = code == 'x' ? 1 : 2 + int.parse(code.substring(1));
        html.write('<h$level id="$headingId">');
      }
    } else if (code.startsWith('C') && argument != null) {
      final label = argument.trim();
      if (label.isNotEmpty) {
        final id = 'pml-chapter-${nextAnchor++}';
        html.write('<span id="$id"></span>');
        headings.add(EreaderPmlHeading(id, label));
      }
    } else if (code == 'Q' && argument != null) {
      final id = _safeFragment(argument);
      if (id != null) html.write('<span id="$id"></span>');
    } else if (code == 'q') {
      if (active.contains('q')) {
        html.write('</a>');
        active.remove('q');
      } else if (argument != null && argument.startsWith('#')) {
        final id = _safeFragment(argument.substring(1));
        if (id != null) {
          active.add('q');
          html.write('<a href="#$id">');
        }
      }
    } else if (code == 'Fn' || code == 'Sd') {
      if (active.contains(code)) {
        html.write('</a>');
        active.remove(code);
      } else if (argument != null) {
        final id = _safeFragment(argument);
        if (id != null) {
          active.add(code);
          html.write('<a href="#${code == 'Fn' ? 'fn' : 'sb'}-$id">');
        }
      }
    } else if (code == 'm' && argument != null) {
      final path = imagePaths[argument];
      if (path != null) html.write('<img src="${escape.convert(path)}" alt=""/>');
    } else if (code == 'w') {
      html.write('<hr/>');
    }
  }

  finishHeading();
  for (final style in active.reversed) {
    html.write(style == 'q' || style == 'Fn' || style == 'Sd' ? '</a>' : '</${tag(style)}>');
  }
  html.write('</body></html>');
  if (html.length > 2 * 64 * 1024 * 1024) {
    throw const InvalidBookException('Rendered eReader HTML exceeds the 128 MiB limit.');
  }
  return EreaderPmlResult(html.toString(), headings);
}

String? _safeFragment(final String value) {
  if (value.isEmpty || value.length > 128 || !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value)) {
    return null;
  }
  return value;
}

/// A heading exposed in document navigation.
final class EreaderPmlHeading {
  /// Creates a navigation heading.
  const EreaderPmlHeading(this.id, this.label);

  /// Fragment identifier in rendered HTML.
  final String id;

  /// Readable heading label.
  final String label;
}

/// Rendered HTML and its heading navigation points.
final class EreaderPmlResult {
  /// Creates a PML projection.
  const EreaderPmlResult(this.html, this.headings);

  /// XHTML-compatible HTML content.
  final String html;

  /// Headings found in the PML source.
  final List<EreaderPmlHeading> headings;
}
