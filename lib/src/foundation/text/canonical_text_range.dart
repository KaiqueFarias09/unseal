import 'canonical_text_snapshot.dart';

/// An inclusive-start, exclusive-end range bound to one
/// [CanonicalTextSnapshot].
///
/// Offsets are UTF-16 code units, not bytes, runes, graphemes or
/// tokens; astral text occupies two units. A point range uses
/// [start] == [end]. Validity never certifies a grapheme or surrogate
/// boundary — conversions that would land mid-pair report that they
/// cannot represent the target instead of shifting it.
final class CanonicalTextRange {
  /// Creates a range over [snapshot]; [ArgumentError] reports a range
  /// outside `0 <= start <= end <= snapshot.utf16Length`.
  CanonicalTextRange({required this.snapshot, required this.start, required this.end}) {
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'Must be non-negative');
    }
    if (end < start) {
      throw ArgumentError.value(end, 'end', 'Must not precede the inclusive start');
    }
    if (end > snapshot.utf16Length) {
      throw ArgumentError.value(
        end,
        'end',
        'Must not exceed the snapshot length (${snapshot.utf16Length})',
      );
    }
  }

  /// The snapshot this range addresses.
  final CanonicalTextSnapshot snapshot;

  /// The inclusive first code unit.
  final int start;

  /// The exclusive end: one past the last code unit.
  final int end;

  /// Creates the point range selecting no characters at [offset].
  factory CanonicalTextRange.point({
    required final CanonicalTextSnapshot snapshot,
    required final int offset,
  }) {
    return CanonicalTextRange(snapshot: snapshot, start: offset, end: offset);
  }

  /// Whether the range selects no characters ([start] == [end]).
  bool get isPoint => start == end;

  /// The text the range selects.
  String get text => snapshot.text.substring(start, end);

  /// Whether both ranges address the same identity, occurrence,
  /// profile, text revision and bounds — reuse compares the full
  /// tuple, not just the numbers.
  bool sameRange(final CanonicalTextRange other) {
    return snapshot.sameIdentity(other.snapshot) && start == other.start && end == other.end;
  }

  @override
  String toString() => 'CanonicalTextRange($start..$end of ${snapshot.utf16Length})';
}
