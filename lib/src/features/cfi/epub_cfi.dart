/// EPUB CFI (Canonical Fragment Identifier) parsing, encoding and
/// resolution.
///
/// Implements the EPUB CFI grammar used for position sync, highlights
/// and deep links: element and character-data steps, spine breaks
/// (`!`), character offsets (`:`), bracket assertions with escaping,
/// `;s=` side biasing, and the comma-separated range form. Temporal
/// (`~`) and spatial (`@`) terminators are intentionally not
/// supported and rejected with a [FormatException].
///
/// Two addressing levels share this model:
///
/// * book-level CFIs (`epubcfi(/6/4!/4/2:10)`) — a spine step then
///   the document steps;
/// * file-local CFIs (`epubcfi(/4/2:10)`) — document steps only, as
///\*   handled by `EpubCfiDocument` and Calibre's own reader.
///
/// Character offsets address the document-text space of
/// `documentText` (visible text inside `<body>`, whitespace as-is).
///
/// See the EPUB CFI spec (`http://www.idpf.org/epub/linking/cfi/`).
library;

/// Reserved CFI characters that must be escaped inside assertions,
/// and the escape marker itself.
final RegExp _escapable = RegExp(r'[\^\[\]\(\);~@!]');

/// Escapes CFI reserved characters in assertion content.
/// Parity: calibre cfi.pyj `escape_for_cfi`.
String escapeForCfi(final String text) =>
    text.replaceAllMapped(_escapable, (final match) => '^${match[0]}');

/// Reverses [escapeForCfi].
/// Parity: calibre cfi.pyj `unescape_from_cfi`.
String unescapeFromCfi(final String text) =>
    text.replaceAllMapped(RegExp(r'\^([\^\[\]\(\);~@!])'), (final match) => match[1]!);

/// One `/N` step of a CFI path, with its optional offset and
/// assertion.
final class EpubCfiStep {
  /// Creates an [EpubCfiStep].
  const EpubCfiStep({required this.index, this.charOffset, this.assertion, this.side});

  /// The step number: even values address element children, odd
  /// values address character-data children (1-based).
  final int index;

  /// Character offset inside the addressed node (`:O`).
  final int? charOffset;

  /// Assertion content (`[...]`), unescaped, without the brackets.
  final String? assertion;

  /// Side bias parsed from a trailing `;s=a|b` in the assertion.
  final String? side;

  /// Whether this step addresses a text node.
  bool get isText => index.isOdd;

  @override
  String toString() =>
      'EpubCfiStep(/$index${charOffset != null ? ':$charOffset' : ''}'
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
  /// Creates an [EpubCfi] from full-grammar paths.
  const EpubCfi({required this.start, this.rangeStart, this.rangeEnd});

  /// Creates a file-local CFI from flat steps — the form Calibre's
  /// reader uses: element/text steps for the path from `<body>` plus
  /// the character offset in the final node, and the id assertion of
  /// the target element.
  factory EpubCfi.simple({
    required final List<int> steps,
    final int charOffset = 0,
    final String? idAssertion,
  }) {
    final all = [...steps];
    final last = all.isEmpty ? 0 : all.removeLast();
    return EpubCfi(
      start: EpubCfiPath(
        segments: [
          EpubCfiSegment(
            steps: [
              for (final index in all) EpubCfiStep(index: index),
              EpubCfiStep(
                index: last,
                charOffset: charOffset > 0 ? charOffset : null,
                assertion: idAssertion,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The leading path (or the whole CFI when this is not a range).
  final EpubCfiPath start;

  /// For ranges, the path between the first and second commas.
  final EpubCfiPath? rangeStart;

  /// For ranges, the path between the second comma and the end.
  final EpubCfiPath? rangeEnd;

  /// Whether this CFI addresses a range.
  bool get isRange => rangeStart != null;

  /// The flat steps of a file-local CFI.
  ///
  /// Only valid when the CFI has a single path with a single segment
  /// (the Calibre reader subset); otherwise throws [StateError].
  List<int> get steps {
    if (start.segments.length != 1) {
      throw StateError('steps is only defined for single-segment CFIs.');
    }
    return start.segments.first.steps.map((final step) => step.index).toList();
  }

  /// The character offset of a file-local CFI (0 when absent).
  int get charOffset => start.segments.last.steps.last.charOffset ?? 0;

  /// The id assertion of the final step of a file-local CFI.
  String? get idAssertion => start.segments.last.steps.last.assertion;

  /// Parses [input] (with or without the `epubcfi(...)` wrapper).
  ///
  /// Throws [FormatException] on malformed CFIs and on unsupported
  /// `~`/`@` terminators. See [tryParse] for the nullable variant.
  static EpubCfi parse(final String input) => _EpubCfiParser(input).parse();

  /// Parses [input], returning `null` instead of throwing when the
  /// CFI is malformed.
  static EpubCfi? tryParse(final String input) {
    try {
      return parse(input);
    } on FormatException {
      return null;
    }
  }

  /// Lexicographic comparison used to sort CFIs of one document:
  /// steps first, then the character offset.
  /// Parity: calibre cfi.pyj `cfi_sort_key`.
  static int compare(final EpubCfi a, final EpubCfi b) {
    final aSteps = a.start.segments.expand((final segment) => segment.steps).toList();
    final bSteps = b.start.segments.expand((final segment) => segment.steps).toList();
    final max = aSteps.length > bSteps.length ? aSteps.length : bSteps.length;
    for (var i = 0; i < max; i++) {
      final sa = i < aSteps.length ? aSteps[i].index : 0;
      final sb = i < bSteps.length ? bSteps[i].index : 0;
      if (sa != sb) return sa.compareTo(sb);
    }
    return a.charOffset.compareTo(b.charOffset);
  }

  /// Encodes this CFI back to its canonical `epubcfi(...)` form,
  /// re-escaping assertion content.
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
      if (step.charOffset != null) {
        buf.write(':${step.charOffset}');
      }
      if (step.assertion != null || step.side != null) {
        final text = step.assertion == null ? '' : escapeForCfi(step.assertion!);
        final side = step.side == null ? '' : ';s=${step.side}';
        buf.write('[$text$side]');
      }
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
    if (_peek() == 0x2C /* , */ ) {
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
    while (_peek() == 0x21 /* ! */ ) {
      _pos++;
      segments.add(_parseSegment());
    }
    return EpubCfiPath(segments: segments);
  }

  EpubCfiSegment _parseSegment() {
    final steps = <EpubCfiStep>[];
    while (true) {
      _skipSpaces();
      if (_peek() != 0x2F /* / */ ) break;
      _pos++;
      final index = _parseInt();
      int? offset;
      if (_peek() == 0x3A /* : */ ) {
        _pos++;
        offset = _parseInt();
      }
      String? assertion;
      String? side;
      if (_peek() == 0x5B /* [ */ ) {
        _pos++;
        final parsed = _parseAssertion();
        assertion = parsed.$1;
        side = parsed.$2;
      }
      steps.add(EpubCfiStep(index: index, charOffset: offset, assertion: assertion, side: side));
    }
    if (steps.isEmpty) _fail('expected a "/" step');
    return EpubCfiSegment(steps: steps);
  }

  /// Reads an escape-aware `[...]` assertion, splitting a trailing
  /// `;s=a|b` side bias.
  (String?, String?) _parseAssertion() {
    final buf = StringBuffer();
    while (_pos < _s.length) {
      final char = _s[_pos];
      if (char == '^' && _pos + 1 < _s.length) {
        buf.write(_s.substring(_pos, _pos + 2));
        _pos += 2;
        continue;
      }
      if (char == ']') {
        _pos++;
        final content = buf.toString();
        final sideMatch = RegExp(r';s=([ab])$').firstMatch(content);
        if (sideMatch != null) {
          return (
            content.substring(0, sideMatch.start).isEmpty
                ? null
                : unescapeFromCfi(content.substring(0, sideMatch.start)),
            sideMatch.group(1),
          );
        }
        return (content.isEmpty ? null : unescapeFromCfi(content), null);
      }
      buf.write(char);
      _pos++;
    }
    _fail('unterminated assertion');
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
