/// Versioned JSON serialization and deserialization for locators.
///
/// The JSON envelope carries a format version under the `'v'` key; decoders reject unknown (or
/// missing) versions by returning null so payloads saved by other versions stay forward-compatible.
library;

import 'book_locator.dart';

/// Version of the JSON envelope emitted by [locatorToJson] and accepted by [locatorFromJson].
const int _locatorJsonVersion = 1;

/// Encodes [locator] into a versioned JSON map.
///
/// Envelope shape: `{'v': 1, 'kind': 'text'|'cfi'|'page', …}` — text locators carry `sectionIndex`,
/// `start`, `end` and an optional nested `quote` (`before`/`text`/`after`), CFI locators carry the
/// opaque `cfi` string, page locators carry `pageIndex` and the optional `total`.
Map<String, Object?> locatorToJson(final BookLocator locator) {
  return switch (locator) {
    TextLocator(:final sectionIndex, :final start, :final end, :final quote) => {
      'v': _locatorJsonVersion,
      'kind': 'text',
      'sectionIndex': sectionIndex,
      'start': start,
      'end': end,
      if (quote != null)
        'quote': {'before': quote.before, 'text': quote.text, 'after': quote.after},
    },
    CfiLocator(:final cfi) => {'v': _locatorJsonVersion, 'kind': 'cfi', 'cfi': cfi},
    PageLocator(:final pageIndex, :final total) => {
      'v': _locatorJsonVersion,
      'kind': 'page',
      'pageIndex': pageIndex,
      'total': ?total,
    },
  };
}

/// Decodes a [BookLocator] from a JSON map produced by [locatorToJson].
///
/// Returns null when the version is missing or unknown, the kind is unknown, a required field is
/// absent or of the wrong type, or the `quote` key is present but malformed — a broken payload
/// never throws and never silently loses its quote.
BookLocator? locatorFromJson(final Map<Object?, Object?> json) {
  if (json['v'] != _locatorJsonVersion) return null;

  switch (json['kind']) {
    case 'text':
      final sectionIndex = _readInt(json['sectionIndex']);
      final start = _readInt(json['start']);
      final end = _readInt(json['end']);
      if (sectionIndex == null || start == null || end == null) return null;

      final quoteValue = json['quote'];
      if (quoteValue != null) {
        final quote = _readTextQuote(quoteValue);
        if (quote == null) return null;

        return TextLocator(sectionIndex: sectionIndex, start: start, end: end, quote: quote);
      }

      return TextLocator(sectionIndex: sectionIndex, start: start, end: end);

    case 'cfi':
      final cfi = json['cfi'];
      if (cfi is! String || cfi.isEmpty) return null;

      return CfiLocator(cfi);

    case 'page':
      final pageIndex = _readInt(json['pageIndex']);
      if (pageIndex == null) return null;

      return PageLocator(pageIndex: pageIndex, total: _readInt(json['total']));

    default:
      return null;
  }
}

/// [value] as an int, or null for any other JSON value.
int? _readInt(final Object? value) => value is int ? value : null;

/// [value] as a [TextQuote], or null unless it is a map carrying the three string fields.
TextQuote? _readTextQuote(final Object? value) {
  if (value is! Map<Object?, Object?>) return null;

  final before = value['before'];
  final text = value['text'];
  final after = value['after'];
  if (before is! String || text is! String || after is! String) return null;

  return TextQuote(before: before, text: text, after: after);
}
