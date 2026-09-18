import 'dart:convert';

import 'package:collection/collection.dart';

import 'bookmark_record.dart';
import 'entities/highlight_record.dart';

const int _annotationFormatVersion = 1;

/// The highlights and bookmarks kept for one book.
final class AnnotationCollection {
  /// Creates a collection.
  const AnnotationCollection({required this.highlights, required this.bookmarks});

  /// The highlights, in any order (the merge re-sorts by position).
  final List<HighlightRecord> highlights;

  /// The bookmarks, in any order (the merge re-sorts by position).
  final List<BookmarkRecord> bookmarks;

  @override
  bool operator ==(final Object other) {
    return other is AnnotationCollection &&
        _highlightsEquality.equals(other.highlights, highlights) &&
        _bookmarksEquality.equals(other.bookmarks, bookmarks);
  }

  @override
  int get hashCode {
    return Object.hash(_highlightsEquality.hash(highlights), _bookmarksEquality.hash(bookmarks));
  }

  static const _highlightsEquality = ListEquality<HighlightRecord>();

  static const _bookmarksEquality = ListEquality<BookmarkRecord>();
}

/// Encodes [collection] as the versioned annotation envelope:
/// `{'formatVersion': 1, 'highlights': [...], 'bookmarks': [...]}`.
///
/// `sectionIndex` is the canonical section field name. A [PaletteHighlightColor] is encoded as its
/// token name (`"yellow"`, …); a [CustomHighlightColor] encodes as
/// `{'light': '#rrggbb', 'dark': '#rrggbb'}`. Timestamps are ISO-8601.
String encodeAnnotations(final AnnotationCollection collection) {
  return jsonEncode(<String, Object?>{
    'formatVersion': _annotationFormatVersion,
    'highlights': [for (final highlight in collection.highlights) _highlightJson(highlight)],
    'bookmarks': [for (final bookmark in collection.bookmarks) _bookmarkJson(bookmark)],
  });
}

/// Decodes an [encodeAnnotations] envelope. Tolerant of per-entry damage: invalid entries are
/// skipped, while a non-map or undecodable envelope, or an unknown (or missing) `formatVersion`,
/// yields null. Missing collections decode to empty ones. Round-trips [encodeAnnotations]
/// losslessly.
AnnotationCollection? decodeAnnotations(final String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }

  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['formatVersion'] != _annotationFormatVersion) return null;

  return AnnotationCollection(
    highlights: _recordsFromJson(decoded['highlights'], _highlightFromJson),
    bookmarks: _recordsFromJson(decoded['bookmarks'], _bookmarkFromJson),
  );
}

Map<String, Object?> _highlightJson(final HighlightRecord highlight) {
  return <String, Object?>{
    'id': highlight.id,
    'sectionIndex': highlight.sectionIndex,
    'start': highlight.start,
    'end': highlight.end,
    'text': highlight.text,
    'before': highlight.before,
    'after': highlight.after,
    'decoration': _decorationName(highlight.decoration),
    'color': switch (highlight.color) {
      PaletteHighlightColor(:final token) => _paletteName(token),
      CustomHighlightColor(:final lightHex, :final darkHex) => <String, String>{
        'light': lightHex,
        'dark': darkHex,
      },
    },
    if (highlight.note != null) 'note': highlight.note,
    'createdAt': highlight.createdAt.toIso8601String(),
    if (highlight.cfi != null) 'cfi': highlight.cfi,
  };
}

Map<String, Object?> _bookmarkJson(final BookmarkRecord bookmark) {
  return <String, Object?>{
    'id': bookmark.id,
    'title': bookmark.title,
    'sectionIndex': bookmark.sectionIndex,
    'charOffset': bookmark.charOffset,
    'createdAt': bookmark.createdAt.toIso8601String(),
    if (bookmark.note != null) 'note': bookmark.note,
  };
}

/// Decodes a JSON list while isolating damage to the malformed entry.
List<T> _recordsFromJson<T>(
  final Object? raw,
  final T? Function(Map<String, dynamic> json) decode,
) {
  final records = <T>[];
  if (raw is! List) return records;

  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) continue;

    final record = decode(entry);
    if (record != null) records.add(record);
  }

  return records;
}

HighlightRecord? _highlightFromJson(final Map<String, dynamic> json) {
  final id = json['id'];
  final sectionIndex = json['sectionIndex'];
  final start = json['start'];
  final end = json['end'];
  final text = json['text'];
  final createdAt = json['createdAt'];
  final color = _colorFromJson(json['color']);
  final decoration = _decorationFromName(json['decoration']);
  final parsedCreatedAt = createdAt is String ? DateTime.tryParse(createdAt) : null;
  if (id is! String ||
      sectionIndex is! int ||
      start is! int ||
      end is! int ||
      text is! String ||
      sectionIndex < 0 ||
      start < 0 ||
      end <= start ||
      color == null ||
      decoration == null ||
      parsedCreatedAt == null) {
    return null;
  }

  return HighlightRecord(
    id: id,
    sectionIndex: sectionIndex,
    start: start,
    end: end,
    text: text,
    before: json['before'] is String ? json['before'] as String : '',
    after: json['after'] is String ? json['after'] as String : '',
    color: color,
    decoration: decoration,
    note: json['note'] is String ? json['note'] as String : null,
    createdAt: parsedCreatedAt,
    cfi: json['cfi'] is String ? json['cfi'] as String : null,
  );
}

BookmarkRecord? _bookmarkFromJson(final Map<String, dynamic> json) {
  final id = json['id'];
  final title = json['title'];
  final createdAt = json['createdAt'];
  final sectionIndex = json['sectionIndex'];
  final charOffset = json['charOffset'];
  final parsedCreatedAt = createdAt is String ? DateTime.tryParse(createdAt) : null;
  if (id is! String ||
      title is! String ||
      sectionIndex is! int ||
      charOffset is! int ||
      sectionIndex < 0 ||
      charOffset < 0 ||
      parsedCreatedAt == null) {
    return null;
  }

  return BookmarkRecord(
    id: id,
    title: title,
    sectionIndex: sectionIndex,
    charOffset: charOffset,
    createdAt: parsedCreatedAt,
    note: json['note'] is String ? json['note'] as String : null,
  );
}

/// Reads a color in either canonical wire shape: a palette token name (`"yellow"`) or a
/// `{'light', 'dark'}` hex pair.
HighlightColor? _colorFromJson(final Object? json) {
  if (json is String) {
    final token = _paletteFromName(json);

    return token == null ? null : PaletteHighlightColor(token);
  }
  if (json is! Map<String, dynamic>) return null;

  final light = json['light'];
  final dark = json['dark'];
  if (light is! String || dark is! String) return null;

  try {
    return CustomHighlightColor(lightHex: light, darkHex: dark);
  } on ArgumentError {
    return null;
  }
}

String _decorationName(final HighlightDecoration decoration) {
  return switch (decoration) {
    HighlightDecoration.background => 'background',
    HighlightDecoration.underline => 'underline',
    HighlightDecoration.strikeout => 'strikeout',
    HighlightDecoration.wavy => 'wavy',
  };
}

HighlightDecoration? _decorationFromName(final Object? name) {
  return switch (name) {
    'background' => HighlightDecoration.background,
    'underline' => HighlightDecoration.underline,
    'strikeout' => HighlightDecoration.strikeout,
    'wavy' => HighlightDecoration.wavy,
    _ => null,
  };
}

String _paletteName(final HighlightPalette palette) {
  return switch (palette) {
    HighlightPalette.yellow => 'yellow',
    HighlightPalette.green => 'green',
    HighlightPalette.blue => 'blue',
    HighlightPalette.pink => 'pink',
    HighlightPalette.purple => 'purple',
    HighlightPalette.red => 'red',
  };
}

HighlightPalette? _paletteFromName(final String name) {
  return switch (name) {
    'yellow' => HighlightPalette.yellow,
    'green' => HighlightPalette.green,
    'blue' => HighlightPalette.blue,
    'pink' => HighlightPalette.pink,
    'purple' => HighlightPalette.purple,
    'red' => HighlightPalette.red,
    _ => null,
  };
}
