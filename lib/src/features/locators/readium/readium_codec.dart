/// Bounded JSON entry points for Readium Locator and position-list
/// payloads: limits run before any allocation, hostile input fails typed.
///
/// Map-level tolerant decoding lives in `readium_locator.dart`; the string
/// entry points here add the preflight, the position-list envelope, and
/// serialization. See `doc/readium-locators.md` for the normative bounds.
library;

import 'dart:convert';

import 'readium_limits.dart';
import 'readium_locator.dart';
import 'readium_position_list.dart';

/// Parses [source] as a Readium Locator JSON document under [limits].
///
/// Throws [ReadiumLocatorLimitException] when the source crosses a bound
/// before the corresponding allocation, and
/// [ReadiumLocatorFormatException] when the source is not JSON or not a
/// structurally valid Locator.
ReadiumLocator readiumLocatorFromJson(
  final String source, {
  final ReadiumLocatorLimits limits = const ReadiumLocatorLimits(),
}) {
  return _decodeBounded(
    source,
    limits,
    (final document) => decodeReadiumLocatorStrict(document, limits: limits),
  );
}

/// Parses [source] as a Readium position-list service document
/// (`{"total": N, "positions": [Locator…]}`) under [limits].
///
/// The failure contract of [readiumLocatorFromJson] applies; an entry the
/// model refuses fails the whole document rather than truncating it.
ReadiumPositionList readiumPositionListFromJson(
  final String source, {
  final ReadiumLocatorLimits limits = const ReadiumLocatorLimits(),
  final ReadiumPositionLimits positionLimits = const ReadiumPositionLimits(),
}) {
  return _decodeBounded(source, limits, (final document) {
    final list = tryDecodeReadiumPositionListModel(
      document,
      limits: limits,
      positionLimits: positionLimits,
    );
    if (list == null) {
      throw const ReadiumLocatorFormatException('Not a structurally valid Readium position list');
    }

    return list;
  });
}

/// Decodes a position-list service document from an already-parsed JSON
/// map, or null when the shape is structurally invalid or above the
/// position limit.
ReadiumPositionList? tryDecodeReadiumPositionListJson(
  final Map<Object?, Object?> json, {
  final ReadiumLocatorLimits limits = const ReadiumLocatorLimits(),
  final ReadiumPositionLimits positionLimits = const ReadiumPositionLimits(),
}) {
  return tryDecodeReadiumPositionListModel(json, limits: limits, positionLimits: positionLimits);
}

/// Serializes [locator] to a JSON string.
String readiumLocatorToJsonString(final ReadiumLocator locator) => jsonEncode(locator.serialize());

/// Serializes [list] to the position-list service JSON shape.
String readiumPositionListToJsonString(final ReadiumPositionList list) =>
    jsonEncode(list.toServiceJson());

T _decodeBounded<T>(
  final String source,
  final ReadiumLocatorLimits limits,
  final T Function(Map<Object?, Object?> document) decode,
) {
  if (source.length > limits.maxJsonCodeUnits) {
    throw ReadiumLocatorLimitException(
      'Readium JSON source is ${source.length} code units, above the '
      '${limits.maxJsonCodeUnits}-unit limit.',
    );
  }
  _preflight(source, limits);

  final Object? document;
  try {
    document = jsonDecode(source);
  } on FormatException catch (error) {
    throw ReadiumLocatorFormatException('Readium JSON source is not valid JSON: ${error.message}');
  }
  if (document is! Map<Object?, Object?>) {
    throw const ReadiumLocatorFormatException('Readium JSON source is not a JSON object');
  }

  try {
    return decode(document);
  } on ReadiumStructuralRejection catch (rejection) {
    throw rejection.isLimit
        ? const ReadiumLocatorLimitException('Readium payload crosses a declared bound.')
        : const ReadiumLocatorFormatException('Not a structurally valid Readium document');
  }
}

/// Counts structure, decoded string lengths, and approximate byte size
/// before `jsonDecode` allocates its object tree — the same
/// measure-before-allocate pass the OPDS 2.0 parser runs.
void _preflight(final String source, final ReadiumLocatorLimits limits) {
  var bytes = 0;
  for (var index = 0; index < source.length; index++) {
    final unit = source.codeUnitAt(index);
    if (unit <= 0x7f) {
      bytes++;
    } else if (unit <= 0x7ff) {
      bytes += 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < source.length) {
      final next = source.codeUnitAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        index++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
    if (bytes > limits.maxJsonCodeUnits) {
      throw ReadiumLocatorLimitException(
        'Readium JSON source exceeds the ${limits.maxJsonCodeUnits}-byte limit.',
      );
    }
  }

  var depth = 0;
  var nodes = 0;
  void countValue(final int atDepth) {
    if (atDepth > limits.maxJsonDepth) {
      throw ReadiumLocatorLimitException(
        'Readium JSON source nests deeper than the ${limits.maxJsonDepth}-level limit.',
      );
    }
    if (++nodes > limits.maxJsonNodes) {
      throw ReadiumLocatorLimitException(
        'Readium JSON source has more than the ${limits.maxJsonNodes}-value limit.',
      );
    }
  }

  var index = 0;
  while (index < source.length) {
    final unit = source.codeUnitAt(index);
    if (unit == 0x7b || unit == 0x5b) {
      countValue(depth + 1);
      depth++;
      index++;
    } else if (unit == 0x7d || unit == 0x5d) {
      if (depth > 0) depth--;
      index++;
    } else if (unit == 0x22) {
      countValue(depth + 1);
      var length = 0;
      index++;
      while (index < source.length) {
        final inner = source.codeUnitAt(index++);
        if (inner == 0x22) break;
        if (inner == 0x5c && index < source.length) {
          if (source.codeUnitAt(index++) == 0x75) index += 4;
        }
        if (++length > limits.maxJsonStringLength) {
          throw ReadiumLocatorLimitException(
            'Readium JSON source has a string above the '
            '${limits.maxJsonStringLength}-character limit.',
          );
        }
      }
    } else if (_isSeparator(unit)) {
      index++;
    } else {
      countValue(depth + 1);
      do {
        index++;
      } while (index < source.length && !_isBoundary(source.codeUnitAt(index)));
    }
  }
}

bool _isSeparator(final int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d || unit == 0x2c || unit == 0x3a;

bool _isBoundary(final int unit) =>
    _isSeparator(unit) ||
    unit == 0x22 ||
    unit == 0x7b ||
    unit == 0x7d ||
    unit == 0x5b ||
    unit == 0x5d;
