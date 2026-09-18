/// EPUB CFI (Canonical Fragment Identifier) parsing, encoding and resolution.
///
/// Implements the EPUB CFI grammar used for position sync, highlights and deep links: element and
/// character-data steps, spine breaks (`!`), character offsets (`:`), bracket assertions with
/// escaping, `;s=` side biasing, and the comma-separated range form. Temporal (`~`) and spatial
/// (`@`) terminators are intentionally not supported and rejected with a [FormatException].
///
/// Two addressing levels share this model:
///
/// * book-level CFIs (`epubcfi(/6/4!/4/2:10)`) — a spine step then the document steps;
/// * file-local CFIs (`epubcfi(/4/2:10)`) — document steps only, handled by the document resolver.
///
/// Character offsets address the document-text space produced by `DocumentTextScanner.scan`
/// (visible text inside `<body>`, whitespace as-is).
///
/// See the EPUB CFI spec (`http://www.idpf.org/epub/linking/cfi/`).
library;

/// Reserved CFI characters that must be escaped inside assertions, and the escape marker itself.
final RegExp _escapable = RegExp(r'[\^\[\]\(\),;~@!]');

/// Escapes CFI reserved characters in assertion content. Reserved characters receive the `^` escape
/// marker required by CFI.
String _escapeAssertion(final String text) {
  return text.replaceAllMapped(_escapable, (final match) => '^${match[0]}');
}

/// Reverses [_escapeAssertion]. Removes one escape marker from each escaped CFI character.
String _unescapeAssertion(final String text) {
  return text.replaceAllMapped(RegExp(r'\^([\^\[\]\(\),;~@!])'), (final match) => match[1]!);
}

/// One `/N` step of a CFI path, with its optional offset and assertion.
final class EpubCfiStep {
  /// Creates an [EpubCfiStep].
  EpubCfiStep({required this.index, this.charOffset, this.assertion, this.side}) {
    if (index < 0) throw RangeError.value(index, 'index', 'must not be negative');
    if (charOffset case final offset? when offset < 0) {
      throw RangeError.value(offset, 'charOffset', 'must not be negative');
    }
    if (side != null && side != 'a' && side != 'b') {
      throw ArgumentError.value(side, 'side', 'must be "a", "b", or null');
    }
  }

  /// The step number: even values address element children, odd values address character-data
  /// children (1-based).
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
  String toString() {
    return 'EpubCfiStep(/$index${charOffset != null ? ':$charOffset' : ''}'
        '${assertion != null ? '[$assertion]' : ''})';
  }
}

/// One `!`-separated segment of a CFI path.
final class EpubCfiSegment {
  /// Creates an [EpubCfiSegment].
  EpubCfiSegment({required final Iterable<EpubCfiStep> steps})
    : steps = List<EpubCfiStep>.unmodifiable(steps) {
    if (this.steps.isEmpty) throw ArgumentError.value(steps, 'steps', 'must not be empty');

    for (final step in this.steps.take(this.steps.length - 1)) {
      if (step.charOffset != null || step.side != null) {
        throw ArgumentError.value(
          steps,
          'steps',
          'a character offset or side bias must terminate its segment',
        );
      }
    }
  }

  /// The steps of this segment, in order.
  final List<EpubCfiStep> steps;

  @override
  String toString() => 'EpubCfiSegment($steps)';
}

/// One complete path of a CFI (possibly spanning documents through `!` segments).
final class EpubCfiPath {
  /// Creates an [EpubCfiPath].
  EpubCfiPath({required final Iterable<EpubCfiSegment> segments})
    : segments = List<EpubCfiSegment>.unmodifiable(segments) {
    for (var i = 0; i + 1 < this.segments.length; i++) {
      final segment = this.segments[i];
      final last = segment.steps.last;
      if (last.charOffset != null || last.side != null) {
        throw ArgumentError.value(
          segments,
          'segments',
          'an offset or side bias must terminate its path',
        );
      }
    }
  }

  /// The segments of this path, in order.
  final List<EpubCfiSegment> segments;

  @override
  String toString() => 'EpubCfiPath($segments)';
}

/// A parsed EPUB CFI: a start location plus, for ranges, the two range boundary paths.
final class EpubCfi {
  /// Creates an [EpubCfi] from full-grammar paths.
  EpubCfi({required this.start, this.rangeStart, this.rangeEnd}) {
    if (start.segments.isEmpty) throw ArgumentError.value(start, 'start', 'must not be empty');
    if ((rangeStart == null) != (rangeEnd == null)) {
      throw ArgumentError('rangeStart and rangeEnd must either both be present or both be absent.');
    }
    if (rangeStart != null && rangeEnd != null) {
      if (_hasOffset(start)) {
        throw ArgumentError.value(start, 'start', 'a range parent path cannot end in an offset');
      }
      if (_hasSideBias(start) || _hasSideBias(rangeStart!) || _hasSideBias(rangeEnd!)) {
        throw ArgumentError('side bias is not valid in an EPUB CFI range.');
      }
    }
  }

  /// Creates a single-segment CFI from flat steps, a character offset in the final node, and an
  /// optional ID assertion on the deepest element step.
  factory EpubCfi.simple({
    required final List<int> steps,
    final int charOffset = 0,
    final String? idAssertion,
  }) {
    if (steps.isEmpty) throw ArgumentError.value(steps, 'steps', 'must not be empty');
    if (charOffset < 0) throw RangeError.value(charOffset, 'charOffset', 'must not be negative');

    final assertionIndex = idAssertion == null
        ? -1
        : steps.lastIndexWhere((final step) => step.isEven);
    if (idAssertion != null && assertionIndex < 0) {
      throw ArgumentError.value(idAssertion, 'idAssertion', 'requires at least one element step');
    }

    return EpubCfi(
      start: EpubCfiPath(
        segments: [
          EpubCfiSegment(
            steps: [
              for (var i = 0; i < steps.length; i++)
                EpubCfiStep(
                  index: steps[i],
                  charOffset: i == steps.length - 1 && charOffset > 0 ? charOffset : null,
                  assertion: i == assertionIndex ? idAssertion : null,
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
  /// Only valid when the CFI has a single path with a single segment (a single-segment file-local
  /// CFI); otherwise throws [StateError].
  List<int> get steps {
    if (start.segments.length != 1 || start.segments.first.steps.isEmpty) {
      throw StateError('steps is only defined for single-segment CFIs.');
    }

    return start.segments.first.steps.map((final step) => step.index).toList();
  }

  /// The character offset of a file-local CFI (0 when absent).
  int get charOffset => start.segments.last.steps.last.charOffset ?? 0;

  /// The id assertion of the final step of a file-local CFI.
  String? get idAssertion {
    for (final step in start.segments.last.steps.reversed) {
      if (!step.isText && step.assertion != null) return step.assertion;
    }

    return null;
  }

  /// Parses a complete `epubcfi(...)` [input].
  ///
  /// Throws [FormatException] on malformed CFIs and on unsupported `~`/`@` terminators. See
  /// [tryParse] for the nullable variant.
  static EpubCfi parse(final String input) => _EpubCfiParser(input).parse();

  /// Parses [input], returning `null` instead of throwing when the CFI is malformed.
  static EpubCfi? tryParse(final String input) {
    try {
      return parse(input);
    } on FormatException {
      return null;
    }
  }

  /// Compares CFIs using the EPUB CFI structural sorting rules. Assertions and side bias do not
  /// participate. Ranges compare by their expanded start location and then their expanded end.
  static int compare(final EpubCfi a, final EpubCfi b) {
    final startOrder = _compareLocations(
      _sortEvents(a.start, continuation: a.rangeStart),
      _sortEvents(b.start, continuation: b.rangeStart),
    );
    if (startOrder != 0) return startOrder;

    return _compareLocations(
      _sortEvents(a.start, continuation: a.rangeEnd),
      _sortEvents(b.start, continuation: b.rangeEnd),
    );
  }

  /// Encodes this CFI back to its canonical `epubcfi(...)` form, re-escaping assertion content.
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

List<(int, int)> _sortEvents(final EpubCfiPath path, {final EpubCfiPath? continuation}) {
  final segments = <List<EpubCfiStep>>[
    for (final segment in path.segments) [...segment.steps],
  ];
  if (continuation != null && continuation.segments.isNotEmpty) {
    segments.last.addAll(continuation.segments.first.steps);
    for (final segment in continuation.segments.skip(1)) {
      segments.add([...segment.steps]);
    }
  }

  final events = <(int, int)>[];
  for (var segmentIndex = 0; segmentIndex < segments.length; segmentIndex++) {
    final steps = segments[segmentIndex];
    for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
      final step = steps[stepIndex];
      events.add((1, step.index));
      final isLast = segmentIndex == segments.length - 1 && stepIndex == steps.length - 1;
      if (step.charOffset != null || (isLast && step.isText)) events.add((0, step.charOffset ?? 0));
    }
    if (segmentIndex + 1 < segments.length) events.add((3, 0));
  }

  return events;
}

int _compareLocations(final List<(int, int)> left, final List<(int, int)> right) {
  final sharedLength = left.length < right.length ? left.length : right.length;
  for (var i = 0; i < sharedLength; i++) {
    final typeOrder = left[i].$1.compareTo(right[i].$1);
    if (typeOrder != 0) return typeOrder;

    final valueOrder = left[i].$2.compareTo(right[i].$2);
    if (valueOrder != 0) return valueOrder;
  }

  return left.length.compareTo(right.length);
}

void _writePath(final StringBuffer buf, final EpubCfiPath path) {
  for (var s = 0; s < path.segments.length; s++) {
    if (s > 0) buf.write('!');
    for (final step in path.segments[s].steps) {
      buf.write('/${step.index}');
      if (step.charOffset != null) buf.write(':${step.charOffset}');
      if (step.assertion != null || step.side != null) {
        final text = step.assertion == null ? '' : _escapeAssertion(step.assertion!);
        final side = step.side == null ? '' : ';s=${step.side}';
        buf.write('[$text$side]');
      }
    }
  }
}

class _EpubCfiParser {
  _EpubCfiParser(this._input) {
    if (!_input.startsWith('epubcfi(')) _fail('expected the "epubcfi(" scheme wrapper');
    if (!_input.endsWith(')')) _fail('missing closing parenthesis');
    _s = _input.substring('epubcfi('.length, _input.length - 1);
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
      rangeStart = _parsePath(allowEmpty: true);
      if (_peek() != 0x2C) _fail('range requires three comma-separated paths');
      _pos++;
      rangeEnd = _parsePath();
      if (_hasOffset(start)) _fail('a range parent path cannot end in an offset');
      if (_hasSideBias(start) || _hasSideBias(rangeStart) || _hasSideBias(rangeEnd)) {
        _fail('side bias is not allowed in a range');
      }
    }
    if (_pos != _s.length) {
      _fail(_peek() == -1 ? 'unexpected end of CFI' : 'unexpected character "$_peekChar"');
    }

    return EpubCfi(start: start, rangeStart: rangeStart, rangeEnd: rangeEnd);
  }

  int _peek() => _pos < _s.length ? _s.codeUnitAt(_pos) : -1;

  String get _peekChar => _pos < _s.length ? _s[_pos] : '';

  EpubCfiPath _parsePath({final bool allowEmpty = false}) {
    final segments = <EpubCfiSegment>[];
    if (allowEmpty && _peek() != 0x2F /* / */ ) {
      return EpubCfiPath(segments: segments);
    }

    segments.add(_parseSegment());
    while (_peek() == 0x21 /* ! */ ) {
      final last = segments.last.steps.last;
      if (last.charOffset != null || last.side != null) {
        _fail('an offset or side bias must terminate its path');
      }
      _pos++;
      segments.add(_parseSegment());
    }

    return EpubCfiPath(segments: segments);
  }

  EpubCfiSegment _parseSegment() {
    final steps = <EpubCfiStep>[];
    while (true) {
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
      if (offset != null && _peek() == 0x2F /* / */ ) {
        _fail('a character offset must terminate its path');
      }
      if (side != null && _peek() == 0x2F /* / */ ) {
        _fail('a side bias must terminate its path');
      }
    }
    if (steps.isEmpty) _fail('expected a "/" step');

    return EpubCfiSegment(steps: steps);
  }

  /// Reads an escape-aware `[...]` assertion, splitting a trailing `;s=a|b` side bias.
  (String?, String?) _parseAssertion() {
    final raw = StringBuffer();
    while (_pos < _s.length) {
      final char = _s[_pos];
      if (char == '^') {
        if (_pos + 1 >= _s.length || !_escapable.hasMatch(_s[_pos + 1])) {
          _fail('invalid assertion escape');
        }
        raw.write(_s.substring(_pos, _pos + 2));
        _pos += 2;
        continue;
      }
      if (char == ']') {
        _pos++;
        final content = raw.toString();
        final side = _trailingSideBias(content);
        if (side != null) {
          final assertion = content.substring(0, content.length - 4);

          return (assertion.isEmpty ? null : _unescapeAssertion(assertion), side);
        }

        if (_containsUnescapedSemicolon(content)) _fail('unsupported assertion parameter');

        return (content.isEmpty ? null : _unescapeAssertion(content), null);
      }
      if (char == '[' ||
          char == '(' ||
          char == ')' ||
          char == ',' ||
          char == '~' ||
          char == '@' ||
          char == '!') {
        _fail('unescaped reserved character in assertion');
      }
      raw.write(char);
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
    if (_pos - start > 1 && _s.codeUnitAt(start) == 0x30) _fail('leading zeros are not allowed');

    return int.parse(_s.substring(start, _pos));
  }
}

bool _hasSideBias(final EpubCfiPath path) {
  return path.segments.any((final segment) => segment.steps.any((final step) => step.side != null));
}

bool _hasOffset(final EpubCfiPath path) {
  return path.segments.isNotEmpty && path.segments.last.steps.last.charOffset != null;
}

String? _trailingSideBias(final String text) {
  if (text.length < 4 ||
      text[text.length - 4] != ';' ||
      text.substring(text.length - 3, text.length - 1) != 's=') {
    return null;
  }

  final side = text[text.length - 1];
  if ((side != 'a' && side != 'b') || !_isUnescapedAt(text, text.length - 4)) return null;

  return side;
}

bool _containsUnescapedSemicolon(final String text) {
  for (var i = 0; i < text.length; i++) {
    if (text[i] == ';' && _isUnescapedAt(text, i)) return true;
  }

  return false;
}

bool _isUnescapedAt(final String text, final int index) {
  var escapes = 0;
  for (var i = index - 1; i >= 0 && text[i] == '^'; i--) {
    escapes++;
  }

  return escapes.isEven;
}
