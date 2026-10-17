import 'dart:collection';

import 'spatial_text_page.dart';
import 'spatial_text_zone.dart';

/// Range queries over one [SpatialTextPage]'s zones: which zone holds a
/// text offset, which zones overlap a text range, which region a zone
/// belongs to.
///
/// Built once per page; queries are binary searches over per-level zone
/// lists sorted by their text range, so search hits, anchor captures and
/// highlight rectangles resolve against the same zone list without
/// rescanning.
final class SpatialZoneLookup {
  /// Builds the lookup over a page's zones.
  SpatialZoneLookup(final SpatialTextPage page)
    : _zones = UnmodifiableListView(List<SpatialTextZone>.of(page.zones)),
      _byKind = <SpatialZoneKind, List<SpatialTextZone>>{
        for (final kind in SpatialZoneKind.values)
          kind: _sortedByStart(<SpatialTextZone>[
            for (final zone in page.zones)
              if (zone.kind == kind) zone,
          ]),
      };

  final UnmodifiableListView<SpatialTextZone> _zones;
  final Map<SpatialZoneKind, List<SpatialTextZone>> _byKind;
  late final List<SpatialTextZone> _sortedZones = _sortedByStart(_zones);

  /// All zones in depth-first reading order.
  List<SpatialTextZone> get zones => _zones;

  /// The word zone whose range contains [offset], or null when the offset
  /// sits between words.
  SpatialTextZone? wordAt(final int offset) => _kindAt(offset, SpatialZoneKind.word);

  /// The line zone whose range contains [offset], or null.
  SpatialTextZone? lineAt(final int offset) => _kindAt(offset, SpatialZoneKind.line);

  /// The region zone whose range contains [offset], or null.
  SpatialTextZone? regionAt(final int offset) => _kindAt(offset, SpatialZoneKind.region);

  /// Every zone overlapping the UTF-16 range `[start, end)`, ordered by
  /// start then end.
  List<SpatialTextZone> zonesIn(final int start, final int end) {
    if (end <= start) return const <SpatialTextZone>[];
    final sorted = _sortedZones;
    var first = _lowerBound(start);
    while (first > 0 && sorted[first - 1].textEnd > start) {
      first--;
    }
    final result = <SpatialTextZone>[];
    for (var i = first; i < sorted.length; i++) {
      final zone = sorted[i];
      if (zone.textStart >= end) break;
      if (zone.textEnd > start) result.add(zone);
    }

    return result;
  }

  /// The region ancestor of each zone in [selected], deduplicated in
  /// reading order — the highlight rectangles a selection paints. Zones
  /// outside this page are ignored.
  List<SpatialTextZone> regionsOf(final Iterable<SpatialTextZone> selected) {
    final seen = <int>{};
    final result = <SpatialTextZone>[];
    for (final zone in selected) {
      var index = _zones.indexOf(zone);
      if (index < 0) continue;
      if (zone.kind != SpatialZoneKind.region) {
        final region = SpatialTextPage.ancestorOf(_zones, index, SpatialZoneKind.region);
        if (region == null) continue;
        index = _zones.indexOf(region);
      }
      if (seen.add(index)) {
        result.add(_zones[index]);
      }
    }

    return result;
  }

  SpatialTextZone? _kindAt(final int offset, final SpatialZoneKind kind) {
    final list = _byKind[kind]!;
    var low = 0;
    var high = list.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final zone = list[mid];
      if (offset < zone.textStart) {
        high = mid - 1;
      } else if (offset >= zone.textEnd) {
        low = mid + 1;
      } else {
        return zone;
      }
    }

    return null;
  }

  static List<SpatialTextZone> _sortedByStart(final List<SpatialTextZone> zones) {
    return List<SpatialTextZone>.of(zones)..sort((final a, final b) {
      final byStart = a.textStart.compareTo(b.textStart);
      if (byStart != 0) return byStart;

      return a.textEnd.compareTo(b.textEnd);
    });
  }

  /// The first zone of [_sortedZones] whose textStart is >= [offset].
  int _lowerBound(final int offset) {
    final list = _sortedZones;
    var low = 0;
    var high = list.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (list[mid].textStart < offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }

    return low;
  }
}
