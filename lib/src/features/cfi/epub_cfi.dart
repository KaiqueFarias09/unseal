/// EPUB CFI (Canonical Fragment Identifier) parsing and encoding.
///
/// Implements the EPUB CFI grammar used for position sync, highlights
/// and deep links: element and character-data steps, spine breaks
/// (`!`), character offsets (`:`), bracket assertions and `;s=` side
/// biasing, plus the comma-separated range form. Temporal (`~`) and
/// spatial (`@`) terminators are intentionally not supported and
/// rejected with a [FormatException].
///
/// See the EPUB Open Container Format CFI spec
/// (`http://www.idpf.org/epub/linking/cfi/`).
library;

/// One `/N` step of a CFI path, with its optional offset and
/// assertion.
final class EpubCfiStep {
  /// Creates an [EpubCfiStep].
  const EpubCfiStep({required this.index, this.charOffset, this.assertion});

  /// The step number: even values address element children, odd
  /// values address character-data children (1-based).
  final int index;

  /// Character offset inside the addressed text node (`:O`), only on
  /// text steps.
  final int? charOffset;

  /// Raw bracket assertion content (`[...]`), without the brackets.
  final String? assertion;

  /// Whether this step addresses a text node.
  bool get isText => index.isOdd;

  @override
  String toString() => 'EpubCfiStep(/$index${charOffset != null ? ':$charOffset' : ''}'
      '${assertion != null ? '[$assertion]' : ''})';
}

/// One `!`-separated segment of a CFI path.
final class EpubCfiSegment {
  /// Creates an [EpubCfiSegment].
  const EpubCfiSegment({required this.steps});

  /// The steps of this segment, in order.
  final List<EpubCfiStep> steps;

  @override
  String toString() => 'EpubCfiSegment($steps)';
}

/// One complete path of a CFI (possibly spanning documents through
/// `!` segments).
final class EpubCfiPath {
  /// Creates an [EpubCfiPath].
  const EpubCfiPath({required this.segments});

  /// The segments of this path, in order.
  final List<EpubCfiSegment> segments;

  @override
  String toString() => 'EpubCfiPath($segments)';
}

/// A parsed EPUB CFI: a start location plus, for ranges, the two
/// range boundary paths.
final class EpubCfi {
  /// Creates an [EpubCfi].
  const EpubCfi({required this.start, this.rangeStart, this.rangeEnd});

  /// The leading path (or the whole CFI when this is not a range).
  final EpubCfiPath start;

  /// For ranges, the path between the first and second commas.
  final EpubCfiPath? rangeStart;

  /// For ranges, the path between the second comma and the end.
  final EpubCfiPath? rangeEnd;

  /// Whether this CFI addresses a range.
  bool get isRange => rangeStart != null;

  /// Parses [input] (with or without the `epubcfi(...)` wrapper).
  ///
  /// Throws [FormatException] on malformed CFIs and on unsupported
  /// `~`/`@` terminators.
  static EpubCfi parse(final String input) => _EpubCfiParser(input).parse();

  /// Encodes this CFI back to its canonical `epubcfi(...)` form,
  /// preserving assertions and offsets.
  String encode() {
    final buf = StringBuffer('epubcfi(');
    _writePath(buf, start);
    if (rangeStart != null && rangeEnd != null) {
      buf.write(',');
      _writePath(buf, rangeStart!);
      buf.write(',');
      _writePath(buf, rangeEnd!);
    }
    buf.write(')');
    return buf.toString();
  }

  @override
  String toString() => encode();
}

void _writePath(final StringBuffer buf, final EpubCfiPath path) {
  for (var s = 0; s < path.segments.length; s++) {
    if (s > 0) buf.write('!');
    for (final step in path.segments[s].steps) {
      buf.write('/${step.index}');
      if (step.charOffset != null) buf.write(':${step.charOffset}');
      if (step.assertion != null) buf.write('[${step.assertion}]');
    }
  }
}

class _EpubCfiParser {
  _EpubCfiParser(this._input) {
    var s = _input.trim();
    if (s.startsWith('epubcfi(')) {
      if (!s.endsWith(')')) {
        _fail('missing closing parenthesis');
      }
      s = s.substring('epubcfi('.length, s.length - 1);
    }
    _s = s;
  }

  final String _input;
  late String _s;
  var _pos = 0;

  Never _fail(final String message) {
    throw FormatException('Invalid EPUB CFI at position $_pos in "$_input": $message');
  }

  EpubCfi parse() {
    final start = _parsePath();
    EpubCfiPath? rangeStart;
    EpubCfiPath? rangeEnd;
    if (_peek() == 0x2C /* , */) {
      _pos++;
      rangeStart = _parsePath();
      if (_peek() != 0x2C) _fail('range requires three comma-separated paths');
      _pos++;
      rangeEnd = _parsePath();
    }
    if (_pos != _s.length) {
      _fail(_peek() == -1 ? 'unexpected end of CFI' : 'unexpected character "$_peekChar"');
    }
    return EpubCfi(start: start, rangeStart: rangeStart, rangeEnd: rangeEnd);
  }

  int _peek() => _pos < _s.length ? _s.codeUnitAt(_pos) : -1;

  String get _peekChar => _pos < _s.length ? _s[_pos] : '';

  void _skipSpaces() {
    while (_pos < _s.length && (_s[_pos] == ' ' || _s[_pos] == '\t')) {
      _pos++;
    }
  }

  EpubCfiPath _parsePath() {
    final segments = <EpubCfiSegment>[];
    _skipSpaces();
    segments.add(_parseSegment());
    while (_peek() == 0x21 /* ! */) {
      _pos++;
      segments.add(_parseSegment());
    }
    return EpubCfiPath(segments: segments);
  }

  EpubCfiSegment _parseSegment() {
    final steps = <EpubCfiStep>[];
    while (true) {
      _skipSpaces();
      if (_peek() != 0x2F /* / */) break;
      _pos++;
      final index = _parseInt();
      if (index.isOdd) {
        // A text step must carry its offset immediately after.
        if (_peek() == 0x3A /* : */) {
          _pos++;
          steps.add(EpubCfiStep(index: index, charOffset: _parseInt()));
        } else {
          steps.add(EpubCfiStep(index: index));
        }
      } else {
        steps.add(EpubCfiStep(index: index));
      }
      if (_peek() == 0x5B /* [ */) {
        _pos++;
        steps[steps.length - 1] = _withAssertion(steps.last);
      }
      // An offset may also appear before the assertion.
      if (index.isEven && _peek() == 0x3A) {
        _fail('character offsets are only valid on text (odd) steps');
      }
    }
    if (steps.isEmpty) _fail('expected a "/" step');
    return EpubCfiSegment(steps: steps);
  }

  EpubCfiStep _withAssertion(final EpubCfiStep step) {
    final start = _pos;
    while (_pos < _s.length && _s.codeUnitAt(_pos) != 0x5D /* ] */) {
      _pos++;
    }
    if (_pos >= _s.length) _fail('unterminated assertion');
    final content = _s.substring(start, _pos);
    _pos++; // consume ']'
    return EpubCfiStep(
      index: step.index,
      charOffset: step.charOffset,
      assertion: content.isEmpty ? null : content,
    );
  }

  int _parseInt() {
    final start = _pos;
    while (_pos < _s.length && _s.codeUnitAt(_pos) >= 0x30 && _s.codeUnitAt(_pos) <= 0x39) {
      _pos++;
    }
    if (_pos == start) _fail('expected an integer');
    return int.parse(_s.substring(start, _pos));
  }
}
