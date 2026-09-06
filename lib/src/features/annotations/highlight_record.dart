/// How a highlight draws over the text. Orthogonal to
/// [HighlightColor]: a wavy underline in green is a valid combination
/// (Calibre's kind/decoration split).
enum HighlightDecoration {
  /// Marker behind the text (Calibre's `color` kind).
  background('background'),

  /// Straight underline.
  underline('underline'),

  /// Line through the text.
  strikeout('strikeout'),

  /// Wavy underline (Calibre's proofreading decoration).
  wavy('wavy');

  const HighlightDecoration(this.wireName);

  /// The name persisted in JSON and sent to rendering bridges.
  final String wireName;

  /// Parses the persisted wire name; null for an unknown name.
  static HighlightDecoration? fromWireName(final String? name) {
    for (final decoration in values) {
      if (decoration.wireName == name) {
        return decoration;
      }
    }
    return null;
  }
}

/// The fixed marker palette: the five Calibre marker colors plus the
/// proofreader red Calibre uses for its wavy/strikeout decorations.
///
/// The package carries the tokens only; the host maps each token to
/// concrete light/dark shades for its theme.
enum HighlightPalette {
  /// Yellow marker.
  yellow,

  /// Green marker.
  green,

  /// Blue marker.
  blue,

  /// Pink marker (the Calibre key named `red`).
  pink,

  /// Purple marker.
  purple,

  /// Proofreader red (the CSS keyword `red`).
  red;

  /// The name persisted in JSON.
  String get wireName => name;

  /// Parses the persisted wire name; null for an unknown name.
  static HighlightPalette? fromWireName(final String? name) {
    for (final token in values) {
      if (token.wireName == name) {
        return token;
      }
    }
    return null;
  }
}

/// A highlight color: a fixed [HighlightPalette] token or a custom
/// light/dark hex pair, so a color picked against a light page stays
/// readable on a dark page (Calibre's builtin_colors_light/dark
/// model).
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

/// A highlight color outside the fixed palette, with one opaque
/// `#rrggbb` value per theme brightness.
final class CustomHighlightColor extends HighlightColor {
  /// Creates a custom color; both values should be opaque `#rrggbb`.
  const CustomHighlightColor({required this.lightHex, required this.darkHex});

  /// Value over light page backgrounds.
  final String lightHex;

  /// Value over dark page backgrounds.
  final String darkHex;

  @override
  bool operator ==(final Object other) =>
      other is CustomHighlightColor && other.lightHex == lightHex && other.darkHex == darkHex;

  @override
  int get hashCode => Object.hash(lightHex, darkHex);
}

/// A persistent highlight: a character range in one section's
/// document text plus the surrounding context to relocate the range
/// if offsets drift, and the EPUB CFI of the highlight start
/// (dual-written with the character offsets for Calibre/Readium
/// interop).
final class HighlightRecord {
  /// Creates a [HighlightRecord].
  const HighlightRecord({
    required this.id,
    required this.sectionIndex,
    required this.start,
    required this.end,
    required this.text,
    required this.before,
    required this.after,
    required this.color,
    this.decoration = HighlightDecoration.background,
    required this.createdAt,
    this.note,
    this.cfi,
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

  /// EPUB CFI of the highlight start. Null for legacy entries that
  /// only carry the character offsets.
  final String? cfi;

  @override
  bool operator ==(final Object other) =>
      other is HighlightRecord &&
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

  @override
  int get hashCode => Object.hash(
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
