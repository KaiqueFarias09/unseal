import '../../../foundation/exceptions/unseal_exception.dart';
import 'anchor_limits.dart';
import 'annotation_anchor.dart';

/// The W3C selector payload was malformed, exceeded a declared limit,
/// or carried a selector type outside the adapter's subset. Hostile
/// input normalizes here — `FormatException` and `RangeError` never
/// leak through the public API.
final class W3cAdapterException extends UnsealException {
  /// Creates the exception with the reason the payload was refused.
  const W3cAdapterException(super.message);
}

/// Why a selector cannot convert into the anchor's UTF-16 space.
enum W3cConversionUnsupportedReason {
  /// A converted bound would land inside a surrogate pair. The pair is
  /// one code point but two UTF-16 units, so no code point offset can
  /// represent it — the conversion reports the impossibility instead
  /// of shifting the target.
  midSurrogatePair,

  /// A position is not a code point index of the text (negative or
  /// past the end).
  positionOutOfRange,
}

/// One conversion outcome: exactly one of converted or unconverted.
sealed class W3cRangeConversion {
  const W3cRangeConversion();
}

/// The selector converted to UTF-16 bounds.
final class W3cRangeConverted extends W3cRangeConversion {
  /// Creates the converted outcome.
  const W3cRangeConverted({required this.start, required this.end});

  /// The inclusive first UTF-16 code unit.
  final int start;

  /// The exclusive end.
  final int end;

  @override
  String toString() => 'W3cRangeConverted($start..$end)';
}

/// The selector cannot represent a bound of this text; nothing was
/// shifted and nothing was guessed.
final class W3cRangeUnconverted extends W3cRangeConversion {
  /// Creates the unconverted outcome.
  const W3cRangeUnconverted(this.reason);

  /// Why the conversion is impossible.
  final W3cConversionUnsupportedReason reason;

  @override
  String toString() => 'W3cRangeUnconverted(${reason.name})';
}

/// A quote conversion that lost supported information along the way
/// (context truncated to the limits, for example). Round trips through
/// the adapter preserve every field the losses list does not name.
final class W3cQuoteConversion<T> {
  /// Creates the conversion result.
  const W3cQuoteConversion({required this.value, this.losses = const <String>[]});

  /// The converted value.
  final T value;

  /// What the conversion could not carry, named (for example
  /// `before truncated`, `after truncated`).
  final List<String> losses;

  /// Whether the conversion lost information.
  bool get hasLosses => losses.isNotEmpty;
}

/// The W3C Web Annotation adapter for durable anchors: the declared
/// subset is `TextQuoteSelector` (exact/prefix/suffix) and
/// `TextPositionSelector`, per the
/// [Web Annotation Data Model](https://www.w3.org/TR/annotation-model/).
///
/// Declared subset and semantics, so "supported" never overstates:
///
/// * **Normalization.** The spec requires the text normalized (markup
///   removed, entities resolved) before counting. Unseal's canonical
///   text is exactly that — the document-text scanner's output — so
///   the adapter takes the canonical text itself as the normalized
///   string and declares no further normalization. Hosts holding raw
///   HTML normalize by capturing through the parser first.
/// * **Units.** Selector positions count Unicode code points in
///   logical order, never UTF-16 code units; the conversions here are
///   the projection in both directions. Astral characters are one code
///   point; combining marks count individually — the adapter does not
///   cluster graphemes (a declared limitation, narrower than the
///   spec's "should not split grapheme clusters" advice).
/// * **Impossible conversions** report `midSurrogatePair` instead of
///   moving the target: a bound inside a surrogate pair has no code
///   point representation.
/// * **Unknown selector types** (RangeSelector, DataPositionSelector,
///   SvgSelector, fragment selectors, …) are outside the subset;
///   [annotationSelectorSupport] names them explicitly. The adapter
///   never silently drops them.
///
/// The adapter is additive to, and independent of, the v1 locator and
/// annotation codecs.
abstract final class W3cAnnotationAdapter {
  const W3cAnnotationAdapter._();

  /// The selector `type` values the subset supports.
  static const Set<String> supportedSelectorTypes = {'TextQuoteSelector', 'TextPositionSelector'};

  /// Converts a [W3cTextPositionSelector]'s code point bounds into
  /// UTF-16 bounds over [canonicalText].
  ///
  /// Returns [W3cRangeUnconverted] with `midSurrogatePair` when a
  /// bound lands inside a surrogate pair, and with
  /// `positionOutOfRange` when a bound is negative or past the text's
  /// code point count.
  static W3cRangeConversion utf16RangeFromPositionSelector(
    final String canonicalText,
    final W3cTextPositionSelector selector,
  ) {
    final start = _utf16OffsetFromCodePointIndex(canonicalText, selector.start);
    if (start == null) {
      return const W3cRangeUnconverted(W3cConversionUnsupportedReason.positionOutOfRange);
    }
    final end = _utf16OffsetFromCodePointIndex(canonicalText, selector.end);
    if (end == null) {
      return const W3cRangeUnconverted(W3cConversionUnsupportedReason.positionOutOfRange);
    }

    return W3cRangeConverted(start: start, end: end);
  }

  /// Converts UTF-16 bounds over [canonicalText] into a position
  /// selector's code point bounds — the inverse of
  /// [utf16RangeFromPositionSelector].
  ///
  /// Returns [W3cRangeUnconverted] with `midSurrogatePair` when a
  /// bound lies inside a surrogate pair: no code point offset
  /// represents the middle of a pair, and the conversion refuses to
  /// move the target. `positionOutOfRange` reports bounds outside the
  /// text.
  static W3cRangeConversion positionSelectorFromUtf16Range(
    final String canonicalText, {
    required final int start,
    required final int end,
  }) {
    final startCodePoint = _codePointIndexFromUtf16Offset(canonicalText, start);
    if (startCodePoint == null) {
      return _reasonFor(canonicalText, start);
    }
    final endCodePoint = _codePointIndexFromUtf16Offset(canonicalText, end);
    if (endCodePoint == null) {
      return _reasonFor(canonicalText, end);
    }

    return W3cRangeConverted(start: startCodePoint, end: endCodePoint);
  }

  /// Converts an anchor quote into the W3C text quote selector shape,
  /// truncating context to [limits] and naming every truncation as a
  /// loss. `exact` is never truncated — capture rejects selections
  /// beyond the quote limit, and an empty exact (a point anchor)
  /// converts to an empty selector string, the honest shape of
  /// "selects nothing".
  static W3cQuoteConversion<W3cTextQuoteSelector> textQuoteSelectorFromAnchorQuote(
    final AnchorQuote quote, {
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    limits.requireValid();
    final losses = <String>[];
    final before = _truncate(quote.before, limits.maxContextLength, 'before truncated', losses);
    final after = _truncate(quote.after, limits.maxContextLength, 'after truncated', losses);

    return W3cQuoteConversion(
      value: W3cTextQuoteSelector(exact: quote.exact, prefix: before, suffix: after),
      losses: losses,
    );
  }

  /// Decodes a W3C text quote selector JSON object into an anchor
  /// quote, truncating context to [limits] and naming every
  /// truncation as a loss.
  ///
  /// Throws [W3cAdapterException] for a malformed object, a missing
  /// `exact`, or a string beyond its limit — hostile payloads fail
  /// typed, never by leaking decoder errors.
  static W3cQuoteConversion<AnchorQuote> anchorQuoteFromTextQuoteSelector(
    final Object? json, {
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    limits.requireValid();
    final selector = decodeTextQuoteSelector(json, limits: limits);
    final losses = <String>[];
    final before = _truncate(selector.prefix, limits.maxContextLength, 'before truncated', losses);
    final after = _truncate(selector.suffix, limits.maxContextLength, 'after truncated', losses);

    return W3cQuoteConversion(
      value: AnchorQuote(exact: selector.exact, before: before, after: after),
      losses: losses,
    );
  }

  /// Decodes a W3C text position selector JSON object.
  ///
  /// Throws [W3cAdapterException] for a malformed object or
  /// non-integer bounds; out-of-range values stay decodable — the
  /// conversions report them against a concrete text.
  static W3cTextPositionSelector decodeTextPositionSelector(
    final Object? json, {
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    limits.requireValid();
    final map = _selectorObject(json, 'TextPositionSelector');
    final start = map['start'];
    final end = map['end'];
    if (start is! int || end is! int) {
      throw const W3cAdapterException('TextPositionSelector needs integer start and end');
    }
    if (start < 0 || end < start) {
      throw const W3cAdapterException('TextPositionSelector bounds must satisfy 0 <= start <= end');
    }

    return W3cTextPositionSelector(start: start, end: end);
  }

  /// Decodes a W3C text quote selector JSON object.
  ///
  /// Throws [W3cAdapterException] for a malformed object, a missing or
  /// over-long string, or a wrong `type`.
  static W3cTextQuoteSelector decodeTextQuoteSelector(
    final Object? json, {
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    limits.requireValid();
    final map = _selectorObject(json, 'TextQuoteSelector');
    final exact = map['exact'];
    if (exact is! String) {
      throw const W3cAdapterException('TextQuoteSelector needs an exact string');
    }
    if (exact.length > limits.maxQuoteLength) {
      throw W3cAdapterException(
        'TextQuoteSelector exact exceeds its limit (${limits.maxQuoteLength})',
      );
    }

    return W3cTextQuoteSelector(
      exact: exact,
      prefix: _limitedField(map['prefix'], 'prefix', limits),
      suffix: _limitedField(map['suffix'], 'suffix', limits),
    );
  }

  /// Encodes a position selector into its W3C JSON shape.
  static Map<String, Object?> encodeTextPositionSelector(final W3cTextPositionSelector selector) {
    return <String, Object?>{
      'type': 'TextPositionSelector',
      'start': selector.start,
      'end': selector.end,
    };
  }

  /// Encodes a quote selector into its W3C JSON shape.
  static Map<String, Object?> encodeTextQuoteSelector(final W3cTextQuoteSelector selector) {
    return <String, Object?>{
      'type': 'TextQuoteSelector',
      'exact': selector.exact,
      'prefix': selector.prefix,
      'suffix': selector.suffix,
    };
  }

  /// Reports which selectors of a W3C annotation body (the `selector`
  /// array of an annotation target) sit inside the subset and which
  /// do not — the explicit declaration C06 requires, so an
  /// exchange never silently drops what it cannot honor.
  ///
  /// Accepts the selector list, a single selector object, or a full
  /// annotation; anything else fails typed.
  static W3cSelectorSupport annotationSelectorSupport(
    final Object? json, {
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    limits.requireValid();
    final selectors = _selectorList(json);
    final supported = <String>[];
    final unsupported = <String>[];

    for (final selector in selectors) {
      if (selector is! Map) {
        throw const W3cAdapterException('Every selector must be an object');
      }
      final type = selector['type'];
      if (type is! String) {
        throw const W3cAdapterException('Every selector must declare its type');
      }
      if (supportedSelectorTypes.contains(type)) {
        supported.add(type);
      } else {
        unsupported.add(type);
      }
    }

    return W3cSelectorSupport(supported: supported, unsupported: unsupported);
  }
}

/// The W3C text quote selector: the exact selection plus the context
/// immediately around it, all already normalized (for this adapter:
/// the canonical document text's own space).
final class W3cTextQuoteSelector {
  /// Creates the selector.
  const W3cTextQuoteSelector({required this.exact, this.prefix = '', this.suffix = ''});

  /// A copy of the selected text, after normalization.
  final String exact;

  /// The snippet immediately before the selection, empty when absent.
  final String prefix;

  /// The snippet immediately after the selection, empty when absent.
  final String suffix;

  @override
  bool operator ==(final Object other) =>
      other is W3cTextQuoteSelector &&
      other.exact == exact &&
      other.prefix == prefix &&
      other.suffix == suffix;

  @override
  int get hashCode => Object.hash(exact, prefix, suffix);

  @override
  String toString() => 'W3cTextQuoteSelector(…$exact…)';
}

/// The W3C text position selector: start (inclusive) and end
/// (exclusive) positions counted in Unicode code points over the
/// normalized text.
final class W3cTextPositionSelector {
  /// Creates the selector.
  const W3cTextPositionSelector({required this.start, required this.end});

  /// The inclusive first code point.
  final int start;

  /// The exclusive end code point.
  final int end;

  @override
  bool operator ==(final Object other) =>
      other is W3cTextPositionSelector && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'W3cTextPositionSelector($start..$end)';
}

/// Which selectors of an exchange payload the subset honors.
final class W3cSelectorSupport {
  /// Creates the report.
  const W3cSelectorSupport({required this.supported, required this.unsupported});

  /// The `type` values inside the subset.
  final List<String> supported;

  /// The `type` values outside the subset, named so nothing is dropped
  /// silently.
  final List<String> unsupported;

  /// Whether the payload is fully inside the subset.
  bool get fullySupported => unsupported.isEmpty;

  @override
  String toString() => 'W3cSelectorSupport(supported: $supported, unsupported: $unsupported)';
}

Map<Object?, Object?> _selectorObject(final Object? json, final String expectedType) {
  if (json is! Map) {
    throw W3cAdapterException('$expectedType payload must be an object');
  }
  final type = json['type'];
  if (type is! String || type != expectedType) {
    throw W3cAdapterException('Selector type must be "$expectedType"');
  }

  return json;
}

List<Object?> _selectorList(final Object? json) {
  if (json is List) return json;
  if (json is Map && json['type'] is String) return [json];
  if (json is Map) {
    final target = json['target'];
    if (target is Map && target['selector'] is List) {
      return target['selector'] as List;
    }
    if (target is List) {
      // An array of targets: flatten their selectors.
      final selectors = <Object?>[];
      for (final entry in target) {
        if (entry is Map && entry['selector'] is List) {
          selectors.addAll(entry['selector'] as List);
        }
      }
      if (selectors.isNotEmpty) return selectors;
    }
  }

  throw const W3cAdapterException(
    'Provide a selector list, a selector object, or an annotation target body',
  );
}

String _limitedField(final Object? value, final String name, final AnchorLimits limits) {
  if (value == null) return '';
  if (value is! String) {
    throw W3cAdapterException('TextQuoteSelector $name must be a string when present');
  }
  if (value.length > limits.maxContextLength * 4) {
    throw W3cAdapterException(
      'TextQuoteSelector $name exceeds its limit '
      '(${limits.maxContextLength * 4} code units)',
    );
  }

  return value;
}

String _truncate(
  final String value,
  final int maxLength,
  final String loss,
  final List<String> losses,
) {
  if (value.length <= maxLength) return value;
  losses.add(loss);

  return value.substring(0, maxLength);
}

/// The UTF-16 offset of code point index [codePointIndex] in [text],
/// or null when the index is not a code point boundary count of the
/// text (negative or past the end).
int? _utf16OffsetFromCodePointIndex(final String text, final int codePointIndex) {
  if (codePointIndex < 0) return null;
  var units = 0;
  var codePoints = 0;
  while (units < text.length) {
    if (codePoints == codePointIndex) return units;
    units += _codePointSize(text, units);
    codePoints++;
  }

  return codePointIndex == codePoints ? units : null;
}

/// The code point index of UTF-16 offset [offset] in [text], or null
/// when [offset] lies inside a surrogate pair or past the text.
int? _codePointIndexFromUtf16Offset(final String text, final int offset) {
  if (offset < 0 || offset > text.length) return null;
  var units = 0;
  var codePoints = 0;
  while (units < offset) {
    units += _codePointSize(text, units);
    codePoints++;
  }

  return units == offset ? codePoints : null;
}

/// The UTF-16 size of the code point at [units]: two for a surrogate
/// pair, one otherwise (including a lone surrogate).
int _codePointSize(final String text, final int units) {
  final unit = text.codeUnitAt(units);
  final isLead = unit >= 0xD800 && unit <= 0xDBFF;
  if (!isLead || units + 1 >= text.length) return 1;
  final next = text.codeUnitAt(units + 1);
  final isTrail = next >= 0xDC00 && next <= 0xDFFF;

  return isTrail ? 2 : 1;
}

/// Classifies why [offset] has no code point representation in [text].
W3cRangeConversion _reasonFor(final String text, final int offset) {
  final insidePair =
      offset > 0 &&
      offset < text.length &&
      _isTrailSurrogate(text.codeUnitAt(offset)) &&
      _isLeadSurrogate(text.codeUnitAt(offset - 1));

  return W3cRangeUnconverted(
    insidePair
        ? W3cConversionUnsupportedReason.midSurrogatePair
        : W3cConversionUnsupportedReason.positionOutOfRange,
  );
}

bool _isLeadSurrogate(final int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isTrailSurrogate(final int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
