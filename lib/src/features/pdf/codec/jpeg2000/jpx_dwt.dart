import 'dart:typed_data';

import 'jpx_exception.dart';

/// 9/7 lifting constants of OpenJPEG (Table F.4 of ISO/IEC 15444-1).
/// The high-pass scale uses OpenJPEG's historic `two_invK`, whose
/// deviation from 2/K is compensated by the band step sizes.
const double _kAlpha = -1.586134342;
const double _kBeta = -0.052980118;
const double _kGamma = 0.882911075;
const double _kDelta = 0.443506852;
const double _kK = 1.230174105;
const double _kTwoInvK = 1.625732422;

const int _intMax = 0x7FFFFFFF;
const int _intMin = -0x80000000;

int _addNoOverflow(final int a, final int b) {
  if (a > 0 && b > _intMax - a) {
    return _intMax;
  }
  if (a < 0 && b < _intMin - a) {
    return _intMin;
  }
  return a + b;
}

int _subNoOverflow(final int a, final int b) {
  if (b < 0 && a > _intMax + b) {
    return _intMax;
  }
  if (b > 0 && a < _intMin + b) {
    return _intMin;
  }
  return a - b;
}

/// Arithmetic shift right with identical semantics on the VM (64-bit
/// ints) and on the compiled web build, whose shifts come back
/// uint32-normalized for negative results.
int _shr(final int value, final int bits) => (value >> bits).toSigned(32);

/// Inverse discrete wavelet transform for JPEG 2000 tiles: the exact
/// integer 5/3 lifting of OpenJPEG's scalar path and the float32 9/7
/// pipeline with the same update order and boundary mirroring. Tile
/// buffers are packed: low-pass samples occupy [0, sn), high-pass
/// samples [sn, length).
final class JpxDwt {
  JpxDwt._();

  /// Runs the IDWT over [buffer] (Int32List for 5/3, Float32List for
  /// 9/7) with row stride [width], lifting the resolution stack
  /// [resolutionBounds] from resolution 1 to the top.
  static void inverse({
    required final TypedData buffer,
    required final bool irreversible,
    required final List<(int, int, int, int)> resolutionBounds,
    required final int width,
  }) {
    if (irreversible) {
      if (buffer is! Float32List) {
        throw const JpxException('The 9/7 tile buffer must be float.');
      }
      _forLevels(buffer, resolutionBounds, width, _lift97Line, _lift97Column, true);
    } else {
      if (buffer is! Int32List) {
        throw const JpxException('The 5/3 tile buffer must be int.');
      }
      _forLevels(buffer, resolutionBounds, width, _lift53Line, _lift53Column, false);
    }
  }

  /// Whether OpenJPEG lifts a line of [sn] low-pass and [dn] high-pass
  /// samples starting on parity [cas]: `opj_idwt53_h/v` touch nothing
  /// for an even-start single sample but always handle odd starts
  /// (lengths 1 and 2 are special cases inside the lifts);
  /// `opj_v8dwt_decode` returns early unless `dn > 0 || sn > 1` for an
  /// even start and `sn > 0 || dn > 1` for an odd one.
  static bool _shouldLift(final bool irreversible, final int cas, final int sn, final int dn) {
    if (sn + dn <= 0) {
      // A resolution can be empty in one direction (width 0, height > 0
      // for a one-column tile): there is no line to lift.
      return false;
    }
    if (irreversible) {
      return cas == 0 ? (dn > 0 || sn > 1) : (sn > 0 || dn > 1);
    }
    return cas == 0 ? sn + dn > 1 : true;
  }

  static void _forLevels(
    final TypedData buffer,
    final List<(int, int, int, int)> bounds,
    final int width,
    final void Function(TypedData, int, int, int, int, int) lineLift,
    final void Function(TypedData, int, int, int, int, int) columnLift,
    final bool irreversible,
  ) {
    var previousWidth = bounds[0].$3 - bounds[0].$1;
    var previousHeight = bounds[0].$4 - bounds[0].$2;
    for (var level = 1; level < bounds.length; level++) {
      final (x0, y0, x1, y1) = bounds[level];
      final rowWidth = x1 - x0;
      final rowHeight = y1 - y0;
      final casRow = x0.isOdd ? 1 : 0;
      if (_shouldLift(irreversible, casRow, previousWidth, rowWidth - previousWidth)) {
        for (var row = 0; row < rowHeight; row++) {
          lineLift(buffer, row * width, previousWidth, rowWidth, casRow, 1);
        }
      }
      final casColumn = y0.isOdd ? 1 : 0;
      if (_shouldLift(irreversible, casColumn, previousHeight, rowHeight - previousHeight)) {
        for (var column = 0; column < rowWidth; column++) {
          columnLift(buffer, column, previousHeight, rowHeight, casColumn, width);
        }
      }
      previousWidth = rowWidth;
      previousHeight = rowHeight;
    }
  }

  /// Horizontal 5/3 over one row segment starting at [base]: [low]
  /// low-pass samples then [length] - [low] high-pass ones.
  static void _lift53Line(
    final TypedData typedBuffer,
    final int base,
    final int low,
    final int length,
    final int cas,
    final int stride,
  ) {
    final buffer = typedBuffer as Int32List;
    if (cas == 1 && length <= 2) {
      _idwt53OddShort(buffer, base, low, length, 1);
      return;
    }
    final tmp = Int32List(length);
    if (cas == 0) {
      _idwt53Cas0(buffer, base, base + low, length, tmp);
    } else {
      _idwt53Cas1(buffer, base + low, base, length, tmp);
    }
    for (var index = 0; index < length; index++) {
      buffer[base + index] = tmp[index];
    }
  }

  /// Vertical 5/3 over one column at [base] with row [stride].
  static void _lift53Column(
    final TypedData typedBuffer,
    final int base,
    final int low,
    final int length,
    final int cas,
    final int stride,
  ) {
    final buffer = typedBuffer as Int32List;
    if (cas == 1 && length <= 2) {
      _idwt53OddShort(buffer, base, low, length, stride);
      return;
    }
    final tmp = Int32List(length);
    if (cas == 0) {
      _idwt53Cas0(buffer, base, base + low * stride, length, tmp, stride);
    } else {
      _idwt53Cas1(buffer, base + low * stride, base, length, tmp, stride);
    }
    for (var index = 0; index < length; index++) {
      buffer[base + index * stride] = tmp[index];
    }
  }

  /// The odd-start short lines of `opj_idwt53_h`/`opj_idwt53_v`: one
  /// sample is halved toward zero (`tiledp[0] /= 2`); two samples
  /// (one low-pass at [base], one high-pass at [base] + [low] * [stride])
  /// reconstruct as `out1 = odd - ((even + 1) >> 1)`, `out0 = even + out1`.
  static void _idwt53OddShort(
    final Int32List buffer,
    final int base,
    final int low,
    final int length,
    final int stride,
  ) {
    if (length == 1) {
      buffer[base] = buffer[base] ~/ 2;
      return;
    }
    final even = buffer[base + low * stride];
    final odd = buffer[base];
    final out1 = odd - _shr(even + 1, 1);
    buffer[base] = even + out1;
    buffer[base + stride] = out1;
  }

  /// OpenJPEG `opj_idwt53_h_cas0` / `opj_idwt3_v_cas0` verbatim; the
  /// readers take [evenBase]/[oddBase] with an optional [stride].
  static void _idwt53Cas0(
    final Int32List buffer,
    final int evenBase,
    final int oddBase,
    final int length,
    final Int32List tmp, [
    final int stride = 1,
  ]) {
    var s1n = buffer[evenBase];
    var d1n = buffer[oddBase];
    var s0n = _subNoOverflow(s1n, _shr(d1n + 1, 1));
    var i = 0;
    var j = 0;
    while (i < length - 3) {
      final d1c = d1n;
      final s0c = s0n;
      j++;
      s1n = buffer[evenBase + j * stride];
      d1n = buffer[oddBase + j * stride];
      s0n = _subNoOverflow(s1n, _shr(d1c + d1n + 2, 2));
      tmp[i] = s0c;
      tmp[i + 1] = _addNoOverflow(d1c, _shr(s0c + s0n, 1));
      i += 2;
    }
    tmp[i] = s0n;
    if (length.isOdd) {
      tmp[length - 1] = _subNoOverflow(
        buffer[evenBase + (length - 1) ~/ 2 * stride],
        _shr(d1n + 1, 1),
      );
      tmp[length - 2] = _addNoOverflow(d1n, _shr(s0n + tmp[length - 1], 1));
    } else {
      tmp[length - 1] = _addNoOverflow(d1n, s0n);
    }
  }

  /// OpenJPEG `opj_idwt53_h_cas1` / `opj_idwt3_v_cas1` verbatim.
  static void _idwt53Cas1(
    final Int32List buffer,
    final int evenBase,
    final int oddBase,
    final int length,
    final Int32List tmp, [
    final int stride = 1,
  ]) {
    var s1 = buffer[evenBase + stride];
    var dc = _subNoOverflow(buffer[oddBase], _shr(_addNoOverflow(buffer[evenBase], s1) + 2, 2));
    tmp[0] = _addNoOverflow(buffer[evenBase], dc);
    var i = 1;
    var j = 1;
    final bound = length - 2 - (length.isOdd ? 0 : 1);
    while (i < bound) {
      final s2 = buffer[evenBase + (j + 1) * stride];
      final dn = _subNoOverflow(buffer[oddBase + j * stride], _shr(_addNoOverflow(s1, s2) + 2, 2));
      tmp[i] = dc;
      tmp[i + 1] = _addNoOverflow(s1, _shr(dn + dc, 1));
      dc = dn;
      s1 = s2;
      i += 2;
      j++;
    }
    tmp[i] = dc;
    if (!length.isOdd) {
      final dn = _subNoOverflow(buffer[oddBase + (length ~/ 2 - 1) * stride], _shr(s1 + 1, 1));
      tmp[length - 2] = _addNoOverflow(s1, _shr(dn + dc, 1));
      tmp[length - 1] = dn;
    } else {
      tmp[length - 1] = _addNoOverflow(s1, dc);
    }
  }

  /// Horizontal 9/7 over one row segment starting at [base].
  static void _lift97Line(
    final TypedData typedBuffer,
    final int base,
    final int low,
    final int length,
    final int cas,
    final int stride,
  ) {
    final buffer = typedBuffer as Float32List;
    final lows = Float32List(low);
    final highs = Float32List(length - low);
    for (var index = 0; index < low; index++) {
      lows[index] = buffer[base + index];
    }
    for (var index = 0; index < highs.length; index++) {
      highs[index] = buffer[base + low + index];
    }
    _lift97(lows, highs, cas);
    _interleave97(buffer, base, 1, lows, highs, cas);
  }

  /// Vertical 9/7 over one column at [base] with row [stride].
  static void _lift97Column(
    final TypedData typedBuffer,
    final int base,
    final int low,
    final int length,
    final int cas,
    final int stride,
  ) {
    final buffer = typedBuffer as Float32List;
    final lows = Float32List(low);
    final highs = Float32List(length - low);
    for (var index = 0; index < low; index++) {
      lows[index] = buffer[base + index * stride];
    }
    for (var index = 0; index < highs.length; index++) {
      highs[index] = buffer[base + (low + index) * stride];
    }
    _lift97(lows, highs, cas);
    _interleave97(buffer, base, stride, lows, highs, cas);
  }

  /// Writes the lifted samples back in coordinate order: even positions
  /// take the low-pass phase for cas 0 and the high-pass phase for cas 1.
  /// The longer band (lows for an even start, highs for an odd one) ends
  /// with a sample without a partner, so the loop runs to the longer
  /// length and each band is bounds-checked separately.
  static void _interleave97(
    final Float32List buffer,
    final int base,
    final int stride,
    final Float32List lows,
    final Float32List highs,
    final int cas,
  ) {
    final sn = lows.length;
    final dn = highs.length;
    final count = sn > dn ? sn : dn;
    for (var index = 0; index < count; index++) {
      final even = cas == 0 ? (index < sn ? lows : null) : (index < dn ? highs : null);
      final odd = cas == 0 ? (index < dn ? highs : null) : (index < sn ? lows : null);
      if (even != null) {
        buffer[base + 2 * index * stride] = even[index];
      }
      if (odd != null) {
        buffer[base + (2 * index + 1) * stride] = odd[index];
      }
    }
  }

  /// Sum of the two low-pass neighbours of high-pass sample [index]
  /// with the symmetric extension of `opj_v8dwt_decode_step2`: an odd
  /// start (cas 1) has no left neighbour for the first sample and the
  /// reference reads the right one twice (`fl = wavelet + a`); the last
  /// sample mirrors the left one when the right one is missing.
  static double _lowNeighbours(
    final Float32List lows,
    final int sn,
    final int index,
    final int cas,
  ) {
    final leftIndex = index - cas;
    final rightIndex = index + 1 - cas;
    if (leftIndex < 0) {
      return 2 * lows[rightIndex];
    }
    if (rightIndex >= sn) {
      return 2 * lows[leftIndex];
    }
    return lows[leftIndex] + lows[rightIndex];
  }

  /// The four 9/7 lifting steps over packed low/high arrays with the
  /// standard boundary mirroring OpenJPEG's v8 decoder implements.
  static void _lift97(final Float32List lows, final Float32List highs, final int cas) {
    final sn = lows.length;
    final dn = highs.length;
    for (var index = 0; index < sn; index++) {
      lows[index] = lows[index] * _kK;
    }
    for (var index = 0; index < dn; index++) {
      highs[index] = highs[index] * _kTwoInvK;
    }
    // Undo delta on the low-pass samples.
    final mLow = sn < dn - cas ? sn : dn - cas;
    for (var index = 0; index < mLow; index++) {
      final leftIndex = index - 1 + cas;
      final rightIndex = index + cas;
      final double sum;
      if (leftIndex < 0) {
        sum = 2 * highs[rightIndex];
      } else {
        sum = highs[leftIndex] + highs[rightIndex];
      }
      lows[index] = lows[index] + sum * -_kDelta;
    }
    if (mLow >= 0 && mLow < sn) {
      lows[mLow] = lows[mLow] + (highs[mLow - 1 + cas] * -_kDelta) * 2;
    }
    // Undo gamma on the high-pass samples.
    final mHigh = dn < sn - (1 - cas) ? dn : sn - (1 - cas);
    for (var index = 0; index < mHigh; index++) {
      highs[index] = highs[index] + _lowNeighbours(lows, sn, index, cas) * -_kGamma;
    }
    if (mHigh < dn) {
      highs[mHigh] = highs[mHigh] + (lows[mHigh - cas] * -_kGamma) * 2;
    }
    // Undo beta on the low-pass samples.
    for (var index = 0; index < mLow; index++) {
      final leftIndex = index - 1 + cas;
      final rightIndex = index + cas;
      final double sum;
      if (leftIndex < 0) {
        sum = 2 * highs[rightIndex];
      } else {
        sum = highs[leftIndex] + highs[rightIndex];
      }
      lows[index] = lows[index] + sum * -_kBeta;
    }
    if (mLow >= 0 && mLow < sn) {
      lows[mLow] = lows[mLow] + (highs[mLow - 1 + cas] * -_kBeta) * 2;
    }
    // Undo alpha on the high-pass samples.
    for (var index = 0; index < mHigh; index++) {
      highs[index] = highs[index] + _lowNeighbours(lows, sn, index, cas) * -_kAlpha;
    }
    if (mHigh < dn) {
      highs[mHigh] = highs[mHigh] + (lows[mHigh - cas] * -_kAlpha) * 2;
    }
  }
}
