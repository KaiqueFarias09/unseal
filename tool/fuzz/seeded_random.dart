import 'dart:math';
import 'dart:typed_data';

/// Deterministic pseudo-random source for corpus generation and mutation.
///
/// SplitMix64: tiny, fast, and well distributed. Every generator and
/// mutator in `tool/fuzz/` takes one of these (or a plain seed integer)
/// so the whole corpus and every fuzz case is reproducible from
/// integers alone — no clock, no filesystem, no network.
final class SeededRandom {
  /// Creates a generator from a non-negative 64-bit [seed].
  SeededRandom([this.seed = 0x9E3779B97F4A7C15]) : _state = seed == 0 ? 0x9E3779B97F4A7C15 : seed;

  /// The seed this generator was created from (kept for provenance reports).
  final int seed;

  int _state;

  /// Returns the next raw 64-bit value (may be negative as a Dart int).
  int next64() {
    var z = (_state + 0x9E3779B97F4A7C15) & _mask63x2;
    _state = z;
    z = ((z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9) & _mask63x2;
    z = ((z ^ (z >>> 27)) * 0x94D049BB133111EB) & _mask63x2;
    return z ^ (z >>> 31);
  }

  /// Returns a uniform non-negative value in `[0, max)`; [max] must be positive.
  int below(final int max) {
    if (max <= 0) {
      throw RangeError.range(max, 1, null, 'max');
    }
    return (next64() & _positiveMask) % max;
  }

  /// Returns a uniform value in `[lo, hi]` inclusive.
  int between(final int lo, final int hi) => lo + below(hi - lo + 1);

  /// Returns a uniform double in `[0, 1)`.
  double nextDouble() => (next64() & _positiveMask) / 0x8000000000000000;

  /// Returns true with probability [numerator]/[denominator].
  bool chance(final int numerator, final int denominator) => below(denominator) < numerator;

  /// Returns [length] pseudo-random bytes.
  Uint8List bytes(final int length) {
    final result = Uint8List(length);
    for (var i = 0; i < length; i++) {
      result[i] = below(256);
    }
    return result;
  }

  /// Picks one item from [items]; [items] must not be empty.
  T pick<T>(final List<T> items) => items[below(items.length)];

  /// Returns a lowercase alphanumeric string of [length] characters.
  String alphanumeric(final int length) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(
      List<int>.generate(length, (final _) => alphabet.codeUnitAt(below(alphabet.length))),
    );
  }

  /// Returns a synthetic alternating-consonant/vowel word of [length] letters.
  ///
  /// The output is pronounceable but carries no dictionary meaning, so
  /// sanitized fixtures built from these words cannot collide with real
  /// titles or author names.
  String word(final int length) {
    const consonants = 'bcdfghklmnprstvz';
    const vowels = 'aeiou';
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.writeCharCode(
        i.isEven
            ? consonants.codeUnitAt(below(consonants.length))
            : vowels.codeUnitAt(below(vowels.length)),
      );
    }
    return buffer.toString();
  }

  static const int _mask63x2 = 0xFFFFFFFFFFFFFFFF;
  static const int _positiveMask = 0x7FFFFFFFFFFFFFFF;
}

/// Deterministic Fisher-Yates shuffle (in place).
void seededShuffle(final List<Object> items, final SeededRandom random) {
  for (var i = items.length - 1; i > 0; i--) {
    final j = random.below(i + 1);
    final tmp = items[i];
    items[i] = items[j];
    items[j] = tmp;
  }
}

/// Clamps [value] into `[lo, hi]`.
int clampInt(final int value, final int lo, final int hi) => max(lo, min(value, hi));
