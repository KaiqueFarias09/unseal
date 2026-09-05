/// The page-flow direction of a book's spine: how a reading
/// application should order the pages of a facing-page spread and
/// which direction the "next page" gesture moves toward.
///
/// Mirrors the EPUB spine `page-progression-direction` attribute and
/// Calibre's model of it: the attribute only carries `ltr` or `rtl`
/// meaningful values, and anything else (`default`, an absent
/// attribute, or a malformed value) carries no signal.
enum PageProgressionDirection {
  /// Pages flow left to right (Latin, Cyrillic, Greek scripts).
  ltr,

  /// Pages flow right to left (Arabic, Hebrew, Persian, Urdu scripts).
  rtl,

  /// The book declares no direction, or declares one this package
  /// cannot interpret. Hosts usually fall back to the book's language
  /// (see `EpubBook.effectivePageProgressionDirection`) or to `ltr`.
  unspecified;

  /// Parses the raw OPF spine attribute [value]. Only the exact spec
  /// values `ltr` and `rtl` are meaningful; `default`, null, and any
  /// other value degrade to [unspecified], mirroring Calibre which
  /// only stores `ltr`/`rtl` from the OPF.
  static PageProgressionDirection fromSpineValue(final String? value) => switch (value) {
    'ltr' => ltr,
    'rtl' => rtl,
    _ => unspecified,
  };

  /// Rebuilds a direction from its [name] as produced by `.name` on
  /// the wire. Unknown or missing names degrade to [unspecified].
  static PageProgressionDirection fromName(final String? name) => switch (name) {
    'ltr' => ltr,
    'rtl' => rtl,
    'unspecified' => unspecified,
    _ => unspecified,
  };
}
