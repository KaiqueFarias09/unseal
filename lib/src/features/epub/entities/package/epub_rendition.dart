/// How an EPUB content document is laid out.
enum EpubLayout {
  /// Content adapts to the available viewport.
  reflowable,

  /// Content has a fixed page geometry.
  prePaginated,
}

/// Preferred display orientation declared by an EPUB.
enum EpubOrientation {
  /// The reading system chooses an orientation.
  auto,

  /// Landscape orientation is preferred.
  landscape,

  /// Portrait orientation is preferred.
  portrait,
}

/// Preferred synthetic spread behavior.
enum EpubSpread {
  /// The reading system chooses whether to make synthetic spreads.
  auto,

  /// Display one document at a time.
  none,

  /// Permit spreads in both orientations.
  both,

  /// Permit spreads in landscape orientation.
  landscape,

  /// Permit spreads in portrait orientation.
  portrait,
}

/// Preferred handling of content that overflows a viewport.
enum EpubFlow {
  /// The reading system chooses overflow behavior.
  auto,

  /// Paginate overflowing content.
  paginated,

  /// Scroll each content document separately.
  scrolledDoc,

  /// Scroll successive content documents continuously.
  scrolledContinuous,
}

/// Placement of a spine item in a synthetic spread.
enum EpubPageSpread {
  /// Place the item on the left.
  left,

  /// Place the item on the right.
  right,

  /// Center the item by itself, equivalent to disabling a spread for it.
  center,
}

/// Properties declared on a spine item, overriding publication preferences.
final class EpubSpineRendition {
  /// Creates the optional overrides declared on a spine item.
  const EpubSpineRendition({
    this.layout,
    this.orientation,
    this.spread,
    this.flow,
    this.pageSpread,
  });

  /// The item's layout override, if declared.
  final EpubLayout? layout;

  /// The item's orientation override, if declared.
  final EpubOrientation? orientation;

  /// The item's spread override, if declared.
  final EpubSpread? spread;

  /// The item's overflow override, if declared.
  final EpubFlow? flow;

  /// Where the item belongs in a synthetic spread, if declared.
  final EpubPageSpread? pageSpread;
}

/// EPUB 3 display preferences from package metadata and spine properties.
///
/// The defaults match EPUB Reading Systems 3.3. [spineItems] is keyed by the
/// manifest id referenced by each spine `itemref`.
final class EpubRendition {
  /// Creates EPUB display preferences with specification defaults.
  const EpubRendition({
    this.layout = EpubLayout.reflowable,
    this.orientation = EpubOrientation.auto,
    this.spread = EpubSpread.auto,
    this.flow = EpubFlow.auto,
    this.spineItems = const <String, EpubSpineRendition>{},
  });

  /// Publication-wide layout.
  final EpubLayout layout;

  /// Publication-wide orientation preference.
  final EpubOrientation orientation;

  /// Publication-wide synthetic spread preference.
  final EpubSpread spread;

  /// Publication-wide overflow preference.
  final EpubFlow flow;

  /// Item-specific overrides keyed by manifest id.
  final Map<String, EpubSpineRendition> spineItems;

  /// Effective layout for the manifest item referenced by [idref].
  EpubLayout layoutFor(final String idref) => spineItems[idref]?.layout ?? layout;

  /// Effective orientation for the manifest item referenced by [idref].
  EpubOrientation orientationFor(final String idref) =>
      spineItems[idref]?.orientation ?? orientation;

  /// Effective spread setting for the manifest item referenced by [idref].
  EpubSpread spreadFor(final String idref) => spineItems[idref]?.spread ?? spread;

  /// Effective overflow setting for the manifest item referenced by [idref].
  EpubFlow flowFor(final String idref) => spineItems[idref]?.flow ?? flow;

  /// Placement in a synthetic spread, if the spine item declares one.
  ///
  /// A centered item should be displayed by itself even if [spread] permits
  /// synthetic spreads. A null result leaves placement to the reading system.
  EpubPageSpread? pageSpreadFor(final String idref) => spineItems[idref]?.pageSpread;
}
