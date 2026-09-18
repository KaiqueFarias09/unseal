import '../../locators/book_locator.dart';

final RegExp _canonicalHexColorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

/// How a highlight draws over the text. Orthogonal to [HighlightColor]: a wavy underline in green
/// is a valid combination (decoration is independent from the color token).
enum HighlightDecoration {
  /// Marker drawn behind the text.
  background,

  /// Straight underline.
  underline,

  /// Line through the text.
  strikeout,

  /// Wavy underline for proofreading-style emphasis.
  wavy,
}

/// The fixed marker palette: five standard marker colors plus a separate proofreader-red token.
///
/// The package carries the tokens only; the host maps each token to concrete light/dark shades for
/// its theme.
enum HighlightPalette {
  /// Yellow marker.
  yellow,

  /// Green marker.
  green,

  /// Blue marker.
  blue,

  /// Pink marker.
  pink,

  /// Purple marker.
  purple,

  /// Proofreader red (the CSS keyword `red`).
  red,
}

/// A highlight color: a fixed [HighlightPalette] token or a custom light/dark hex pair, so a color
/// picked against a light page stays readable on a dark page while keeping the persisted value
/// stable.
sealed class HighlightColor {
  const HighlightColor();
}

/// One of the fixed [HighlightPalette] colors.
final class PaletteHighlightColor extends HighlightColor {
  /// Creates a palette color from [token].
  const PaletteHighlightColor(this.token);

  /// The fixed palette color.
  final HighlightPalette token;

  /// Yellow marker.
  static const PaletteHighlightColor yellow = PaletteHighlightColor(HighlightPalette.yellow);

  /// Green marker.
  static const PaletteHighlightColor green = PaletteHighlightColor(HighlightPalette.green);

  /// Blue marker.
  static const PaletteHighlightColor blue = PaletteHighlightColor(HighlightPalette.blue);

  /// Pink marker.
  static const PaletteHighlightColor pink = PaletteHighlightColor(HighlightPalette.pink);

  /// Purple marker.
  static const PaletteHighlightColor purple = PaletteHighlightColor(HighlightPalette.purple);

  /// Proofreader red.
  static const PaletteHighlightColor red = PaletteHighlightColor(HighlightPalette.red);

  @override
  bool operator ==(final Object other) => other is PaletteHighlightColor && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

/// A highlight color outside the fixed palette, with one opaque `#rrggbb` value per theme
/// brightness.
final class CustomHighlightColor extends HighlightColor {
  /// Creates a custom color with one opaque `#rrggbb` value per theme.
  factory CustomHighlightColor({required final String lightHex, required final String darkHex}) {
    _validateHexColor(lightHex, 'lightHex');
    _validateHexColor(darkHex, 'darkHex');

    return CustomHighlightColor._(lightHex: lightHex, darkHex: darkHex);
  }

  const CustomHighlightColor._({required this.lightHex, required this.darkHex});

  /// Value over light page backgrounds.
  final String lightHex;

  /// Value over dark page backgrounds.
  final String darkHex;

  @override
  bool operator ==(final Object other) {
    return other is CustomHighlightColor && other.lightHex == lightHex && other.darkHex == darkHex;
  }

  @override
  int get hashCode => Object.hash(lightHex, darkHex);
}

void _validateHexColor(final String value, final String parameterName) {
  if (!_canonicalHexColorPattern.hasMatch(value)) {
    throw ArgumentError.value(value, parameterName, 'must be an opaque #rrggbb color');
  }
}

/// A persistent highlight: a character range in one section's document text plus the surrounding
/// context to relocate the range if offsets drift, and the EPUB CFI of the highlight start (stored
/// alongside the character offsets for import/export interoperability).
final class HighlightRecord {
  /// Creates a [HighlightRecord].
  factory HighlightRecord({
    required final String id,
    required final int sectionIndex,
    required final int start,
    required final int end,
    required final String text,
    required final String before,
    required final String after,
    required final HighlightColor color,
    final HighlightDecoration decoration = HighlightDecoration.background,
    required final DateTime createdAt,
    final String? note,
    final String? cfi,
  }) {
    if (sectionIndex < 0) {
      throw ArgumentError.value(sectionIndex, 'sectionIndex', 'must not be negative');
    }
    if (start < 0) throw ArgumentError.value(start, 'start', 'must not be negative');
    if (end <= start) throw ArgumentError.value(end, 'end', 'must be greater than start');

    return HighlightRecord._(
      id: id,
      sectionIndex: sectionIndex,
      start: start,
      end: end,
      text: text,
      before: before,
      after: after,
      color: color,
      decoration: decoration,
      createdAt: createdAt,
      note: note,
      cfi: cfi,
    );
  }

  const HighlightRecord._({
    required this.id,
    required this.sectionIndex,
    required this.start,
    required this.end,
    required this.text,
    required this.before,
    required this.after,
    required this.color,
    required this.decoration,
    required this.createdAt,
    required this.note,
    required this.cfi,
  });

  /// Unique identifier.
  final String id;

  /// Index of the content section inside the book's reading order.
  final int sectionIndex;

  /// Character range start within the section's document text.
  final int start;

  /// Character range end (exclusive).
  final int end;

  /// The highlighted text (for display and fuzzy relocation).
  final String text;

  /// Context before the highlight (fuzzy relocation).
  final String before;

  /// Context after the highlight (fuzzy relocation).
  final String after;

  /// Marker color (one value per theme brightness).
  final HighlightColor color;

  /// How the marker draws over the text.
  final HighlightDecoration decoration;

  /// Optional note attached to the highlight.
  final String? note;

  /// Creation timestamp (merge ordering key).
  final DateTime createdAt;

  /// EPUB CFI of the highlight start, when the book format supports CFI addressing.
  final String? cfi;

  /// The canonical range and relocation quote represented by this highlight.
  TextLocator get locator {
    return TextLocator(
      sectionIndex: sectionIndex,
      start: start,
      end: end,
      quote: TextQuote(before: before, text: text, after: after),
    );
  }

  /// Returns this highlight with an updated visual style.
  HighlightRecord withStyle({final HighlightColor? color, final HighlightDecoration? decoration}) {
    return HighlightRecord(
      id: id,
      sectionIndex: sectionIndex,
      start: start,
      end: end,
      text: text,
      before: before,
      after: after,
      color: color ?? this.color,
      decoration: decoration ?? this.decoration,
      createdAt: createdAt,
      note: note,
      cfi: cfi,
    );
  }

  /// Returns this highlight with [note], including `null` to clear it.
  HighlightRecord withNote(final String? note) {
    return HighlightRecord(
      id: id,
      sectionIndex: sectionIndex,
      start: start,
      end: end,
      text: text,
      before: before,
      after: after,
      color: color,
      decoration: decoration,
      createdAt: createdAt,
      note: note,
      cfi: cfi,
    );
  }

  @override
  bool operator ==(final Object other) {
    return other is HighlightRecord &&
        other.id == id &&
        other.sectionIndex == sectionIndex &&
        other.start == start &&
        other.end == end &&
        other.text == text &&
        other.before == before &&
        other.after == after &&
        other.color == color &&
        other.decoration == decoration &&
        other.note == note &&
        other.createdAt == createdAt &&
        other.cfi == cfi;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      sectionIndex,
      start,
      end,
      text,
      before,
      after,
      color,
      decoration,
      note,
      createdAt,
      cfi,
    );
  }
}
