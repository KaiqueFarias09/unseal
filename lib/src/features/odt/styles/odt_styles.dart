part of '../parse_odt_book.dart';

/// Text and list styles needed by the XHTML renderer.
final class _OdtStyleCatalog {
  const _OdtStyleCatalog._(this._styles, this._listKinds);

  /// Builds a catalog from automatic and named styles in [package].
  factory _OdtStyleCatalog.fromPackage(final _OdtPackage package) {
    final values = <String, _OdtStyle>{};
    final listKinds = <String, String>{};
    final roots = <XmlElement>[
      if (package.styles != null) package.styles!.rootElement,
      package.content.rootElement,
    ];
    for (final root in roots) {
      for (final element in root.descendants.whereType<XmlElement>()) {
        final local = element.name.local;
        if (local == 'style') {
          final name = _odtAttribute(element, 'name');
          if (name == null || name.isEmpty) continue;
          final properties = _odtFindDescendant(element, 'text-properties');
          values[name] = _OdtStyle(
            name: _odtAttribute(element, 'display-name') ?? name,
            bold: _isBold(_odtAttribute(properties, 'font-weight')),
            italic: _isItalic(_odtAttribute(properties, 'font-style')),
            underline: _isUnderline(_odtAttribute(properties, 'text-underline-style')),
          );
        } else if (local == 'list-style') {
          final name = _odtAttribute(element, 'name');
          if (name == null || name.isEmpty) continue;
          final isNumbered = element.descendants.whereType<XmlElement>().any((final child) {
            return child.name.local == 'level-style-number' ||
                child.name.local == 'list-level-style-number';
          });
          listKinds[name] = isNumbered ? 'ol' : 'ul';
        }
      }
    }

    return _OdtStyleCatalog._(values, listKinds);
  }

  final Map<String, _OdtStyle> _styles;
  final Map<String, String> _listKinds;

  /// Resolves the display name used to infer heading levels.
  String? textStyleName(final String? name) => name == null ? null : _styles[name]?.name;

  /// Resolves an ODT list style to an HTML ordered or unordered list tag.
  String listKind(final String? name) => name == null ? 'ul' : _listKinds[name] ?? 'ul';

  /// Applies supported inline semantics for the named text style.
  String wrap(final String? name, final String content) {
    final style = name == null ? null : _styles[name];
    if (style == null || content.isEmpty) return content;

    var wrapped = content;
    if (style.bold) wrapped = '<strong>$wrapped</strong>';
    if (style.italic) wrapped = '<em>$wrapped</em>';
    if (style.underline) wrapped = '<u>$wrapped</u>';

    return wrapped;
  }
}

final class _OdtStyle {
  const _OdtStyle({
    required this.name,
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });

  final String name;
  final bool bold;
  final bool italic;
  final bool underline;
}

bool _isBold(final String? value) => value != null && value.toLowerCase() == 'bold';

bool _isItalic(final String? value) => value != null && value.toLowerCase() == 'italic';

bool _isUnderline(final String? value) => value != null && value.toLowerCase() != 'none';
