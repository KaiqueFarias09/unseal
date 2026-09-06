import 'dart:convert';

import 'package:collection/collection.dart';

import 'bookmark_record.dart';
import 'highlight_record.dart';

/// The envelope version [encodeAnnotations] writes and the only
/// version [decodeAnnotations] accepts.
const int annotationFormatVersion = 1;

/// The highlights and bookmarks kept for one book.
final class AnnotationCollection {
  /// Creates a collection.
  const AnnotationCollection({required this.highlights, required this.bookmarks});

  /// The highlights, in any order (the merge re-sorts by position).
  final List<HighlightRecord> highlights;

  /// The bookmarks, in any order (the merge re-sorts by position).
  final List<BookmarkRecord> bookmarks;

  @override
  bool operator ==(final Object other) =>
      other is AnnotationCollection &&
      _highlightsEquality.equals(other.highlights, highlights) &&
      _bookmarksEquality.equals(other.bookmarks, bookmarks);

  @override
  int get hashCode =>
      Object.hash(_highlightsEquality.hash(highlights), _bookmarksEquality.hash(bookmarks));

  static const _highlightsEquality = ListEquality<HighlightRecord>();

  static const _bookmarksEquality = ListEquality<BookmarkRecord>();
}

/// Encodes [collection] as the versioned annotation envelope:
/// `{'formatVersion': 1, 'highlights': [...], 'bookmarks': [...]}`.
///
/// Record shapes follow the viewer's persistence vocabulary, with
/// `sectionIndex` as the canonical section field name. A
/// [PaletteHighlightColor] encodes as its token name
/// (`"yellow"`, …); a [CustomHighlightColor] encodes as
/// `{'light': '#rrggbb', 'dark': '#rrggbb'}`. Timestamps are
/// ISO-8601.
String encodeAnnotations(final AnnotationCollection collection) => jsonEncode(<String, Object?>{
  'formatVersion': annotationFormatVersion,
  'highlights': [for (final highlight in collection.highlights) _highlightJson(highlight)],
  'bookmarks': [for (final bookmark in collection.bookmarks) _bookmarkJson(bookmark)],
});

/// Decodes an [encodeAnnotations] envelope. Tolerant of per-entry
/// damage: invalid entries are skipped, while a non-map or
/// undecodable envelope, or an unknown (or missing)
/// `formatVersion`, yields null. Missing collections decode to
/// empty ones. Round-trips [encodeAnnotations] losslessly.
///
/// Bookmark entries may carry the position either structurally
/// (`sectionIndex` + `charOffset`) or as the viewer's serialized
/// `'eLv1:<sectionIndex>:<charOffset>'` string, which is accepted as
/// a fallback.
AnnotationCollection? decodeAnnotations(final String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  if (decoded['formatVersion'] != annotationFormatVersion) {
    return null;
  }
  return AnnotationCollection(
    highlights: _highlightsFromJson(decoded['highlights']),
    bookmarks: _bookmarksFromJson(decoded['bookmarks']),
  );
}

Map<String, Object?> _highlightJson(final HighlightRecord highlight) => <String, Object?>{
  'id': highlight.id,
  'sectionIndex': highlight.sectionIndex,
  'start': highlight.start,
  'end': highlight.end,
  'text': highlight.text,
  'before': highlight.before,
  'after': highlight.after,
  'decoration': highlight.decoration.wireName,
  'color': switch (highlight.color) {
    PaletteHighlightColor(:final token) => token.wireName,
    CustomHighlightColor(:final lightHex, :final darkHex) => <String, String>{
      'light': lightHex,
      'dark': darkHex,
    },
  },
  'note': highlight.note,
  'createdAt': highlight.createdAt.toIso8601String(),
  if (highlight.cfi != null) 'cfi': highlight.cfi,
};

Map<String, Object?> _bookmarkJson(final BookmarkRecord bookmark) => <String, Object?>{
  'id': bookmark.id,
  'title': bookmark.title,
  'sectionIndex': bookmark.sectionIndex,
  'charOffset': bookmark.charOffset,
  'createdAt': bookmark.createdAt.toIso8601String(),
  if (bookmark.note != null) 'note': bookmark.note,
};

/// Parity with the viewer's `ViewerHighlight.fromJson`: malformed
/// entries are dropped, not thrown.
List<HighlightRecord> _highlightsFromJson(final Object? raw) {
  final highlights = <HighlightRecord>[];
  if (raw is! List) {
    return highlights;
  }
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) {
      continue;
    }
    final highlight = _highlightFromJson(entry);
    if (highlight != null) {
      highlights.add(highlight);
    }
  }
  return highlights;
}

List<BookmarkRecord> _bookmarksFromJson(final Object? raw) {
  final bookmarks = <BookmarkRecord>[];
  if (raw is! List) {
    return bookmarks;
  }
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) {
      continue;
    }
    final bookmark = _bookmarkFromJson(entry);
    if (bookmark != null) {
      bookmarks.add(bookmark);
    }
  }
  return bookmarks;
}

HighlightRecord? _highlightFromJson(final Map<String, dynamic> json) {
  final id = json['id'];
  final sectionIndex = json['sectionIndex'];
  final start = json['start'];
  final end = json['end'];
  final text = json['text'];
  final createdAt = json['createdAt'];
  final color = _colorFromJson(json['color']);
  final decoration = json['decoration'] is String
      ? HighlightDecoration.fromWireName(json['decoration'] as String)
      : null;
  final parsedCreatedAt = createdAt is String ? DateTime.tryParse(createdAt) : null;
  if (id is! String ||
      sectionIndex is! int ||
      start is! int ||
      end is! int ||
      text is! String ||
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
  final parsedCreatedAt = createdAt is String ? DateTime.tryParse(createdAt) : null;
  if (id is! String || title is! String || parsedCreatedAt == null) {
    return null;
  }
  final position = _positionFromJson(json);
  if (position == null) {
    return null;
  }
  return BookmarkRecord(
    id: id,
    title: title,
    sectionIndex: position.$1,
    charOffset: position.$2,
    createdAt: parsedCreatedAt,
    note: json['note'] is String ? json['note'] as String : null,
  );
}

/// Reads the bookmark position: the structured fields when both are
/// present, otherwise the viewer's serialized
/// `'eLv1:<sectionIndex>:<charOffset>'` string.
(int, int)? _positionFromJson(final Map<String, dynamic> json) {
  final sectionIndex = json['sectionIndex'];
  final charOffset = json['charOffset'];
  if (sectionIndex is int && charOffset is int) {
    return (sectionIndex, charOffset);
  }
  final position = json['position'];
  if (position is! String) {
    return null;
  }
  final parts = position.split(':');
  if (parts.length != 3 || parts[0] != 'eLv1') {
    return null;
  }
  final parsedSection = int.tryParse(parts[1]);
  final parsedOffset = int.tryParse(parts[2]);
  if (parsedSection == null || parsedOffset == null) {
    return null;
  }
  return (parsedSection, parsedOffset);
}

/// Reads a color in either wire shape: a palette token name
/// (`"yellow"`) or a `{'light', 'dark'}` hex pair.
HighlightColor? _colorFromJson(final Object? json) {
  if (json is String) {
    final token = HighlightPalette.fromWireName(json);
    return token == null ? null : PaletteHighlightColor(token);
  }
  if (json is! Map<String, dynamic>) {
    return null;
  }
  final light = json['light'];
  final dark = json['dark'];
  if (light is! String || dark is! String || !_isHexColor(light) || !_isHexColor(dark)) {
    return null;
  }
  return CustomHighlightColor(lightHex: light, darkHex: dark);
}

/// Whether [value] is an opaque `#rrggbb` string (the leading `#`
/// optional, mirroring the viewer's hex parsing).
bool _isHexColor(final String value) => RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(value);
