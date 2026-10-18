/// The versioned position-list generation profile
/// `unseal.readium.positions/1`, fixed in `doc/readium-locators.md`
/// before the implementation.
///
/// The 1024-scalar density is Unseal's declared choice — not a Readium
/// requirement, and no claim that another producer's position list
/// matches it.
library;

/// The generation profile every list declares.
final class ReadiumPositionProfile {
  const ReadiumPositionProfile._({
    required this.id,
    required this.scalarInterval,
    required this.schemaVersion,
  });

  /// The only profile the current generator implements.
  static const ReadiumPositionProfile v1 = ReadiumPositionProfile._(
    id: 'unseal.readium.positions/1',
    scalarInterval: 1024,
    schemaVersion: 1,
  );

  /// The profile identifier hosts persist alongside a list.
  final String id;

  /// Reflowable anchor spacing in Unicode scalar values; the first
  /// position of each occurrence is the scalar-0 anchor.
  final int scalarInterval;

  /// The profile's own schema version.
  final int schemaVersion;

  /// The UTF-16 offsets that anchor one occurrence whose canonical text
  /// is [text]: the scalar walk records every code-unit offset at which
  /// the scalar count reaches a multiple of [scalarInterval], starting
  /// at offset 0 — the occurrence's first position. The anchor at an
  /// astral scalar sits on the pair's own (high surrogate) offset; a
  /// surrogate pair is never split.
  ///
  /// Empty text anchors once, at offset 0.
  List<int> anchorUtf16Offsets(final String text) {
    if (text.isEmpty) return const <int>[0];

    final interval = scalarInterval;
    final units = text.codeUnits;
    final offsets = <int>[0];
    var scalars = 0;
    var nextAnchor = interval;
    var offset = 0;
    while (offset < units.length) {
      // The scalar about to start is the boundary anchor: its first code
      // unit is the anchor site, and a surrogate pair never splits.
      if (scalars == nextAnchor) {
        offsets.add(offset);
        nextAnchor += interval;
      }
      final unit = units[offset];
      final isPair =
          unit >= 0xd800 &&
          unit <= 0xdbff &&
          offset + 1 < units.length &&
          units[offset + 1] >= 0xdc00 &&
          units[offset + 1] <= 0xdfff;
      offset += isPair ? 2 : 1;
      scalars++;
    }

    return offsets;
  }
}
