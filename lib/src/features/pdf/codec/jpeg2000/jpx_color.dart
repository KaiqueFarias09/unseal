import 'dart:math' as math;
import 'dart:typed_data';

import 'jpx_exception.dart';

/// Reference-grid projections of the OpenJPEG 2.5.4 utility
/// (doc/jpeg2000-precision.md, output contract rules 3 and 4): the
/// `-upsample` nearest-neighbour replication and the `color.c` sYCC to
/// RGB conversions for the 4:4:4, 4:2:2 and 4:2:0 layouts.
final class JpxColor {
  JpxColor._();

  /// Chroma layout label of three components: `444`, `422`, `420`, or
  /// null for every other grid combination.
  static String? chromaLayout(final List<(int, int)> grids) {
    if (grids.length != 3 || grids[0] != (1, 1) || grids[1] != grids[2]) {
      return null;
    }
    return switch (grids[1]) {
      (1, 1) => '444',
      (2, 1) => '422',
      (2, 2) => '420',
      _ => null,
    };
  }

  /// `opj_decompress -upsample`: replicates [source] (a component plane
  /// of [sourceWidth] x [sourceHeight] samples at grid step [dx], [dy]
  /// whose first sample sits [xoff], [yoff] reference columns/rows after
  /// the image origin) onto a [width] x [height] reference-grid plane.
  /// Columns and rows before the first sample are zero, the last sample
  /// extends to the edges.
  static TypedDataList<int> upsample({
    required final TypedDataList<int> source,
    required final int sourceWidth,
    required final int sourceHeight,
    required final int dx,
    required final int dy,
    required final int xoff,
    required final int yoff,
    required final int width,
    required final int height,
  }) {
    if (xoff < 0 || xoff >= dx || yoff < 0 || yoff >= dy) {
      throw const JpxException('JPEG 2000 component grid offset escapes its sampling step.');
    }
    final TypedDataList<int> target = source is Uint8List
        ? Uint8List(width * height)
        : Uint16List(width * height);
    final lastRow = sourceHeight - 1;
    final lastColumn = sourceWidth - 1;
    var y = yoff;
    var sourceRow = 0;
    while (y < height) {
      final rowBase = y * width;
      final sourceBase = math.min(sourceRow, lastRow) * sourceWidth;
      var x = xoff;
      var sourceColumn = 0;
      while (x < width) {
        final value = source[sourceBase + math.min(sourceColumn, lastColumn)];
        final end = math.min(x + dx, width);
        for (var column = x; column < end; column++) {
          target[rowBase + column] = value;
        }
        x = end;
        sourceColumn++;
      }
      final end = math.min(y + dy, height);
      for (var row = y + 1; row < end; row++) {
        target.setRange(row * width, (row + 1) * width, target, rowBase);
      }
      y = end;
      sourceRow++;
    }
    return target;
  }

  /// OpenJPEG `color_sycc_to_rgb` dispatched on [layout]; [planes] are
  /// the Y, Cb, Cr native planes (Cb and Cr share [chromaWidth] and
  /// [chromaHeight]), [x0]/[y0] the image origin whose parity selects
  /// the reference's first-column/first-row `Cb = Cr = 0` rule. Returns
  /// R, G, B planes of [width] x [height].
  static List<TypedDataList<int>> syccToRgb({
    required final String layout,
    required final List<TypedDataList<int>> planes,
    required final int width,
    required final int height,
    required final int chromaWidth,
    required final int chromaHeight,
    required final int precision,
    required final int x0,
    required final int y0,
  }) {
    final y = planes[0];
    final cb = planes[1];
    final cr = planes[2];
    final count = width * height;
    final TypedDataList<int> r = precision <= 8 ? Uint8List(count) : Uint16List(count);
    final TypedDataList<int> g = precision <= 8 ? Uint8List(count) : Uint16List(count);
    final TypedDataList<int> b = precision <= 8 ? Uint8List(count) : Uint16List(count);
    final converter = _Sycc(precision, r, g, b);
    switch (layout) {
      case '444':
        if (cb.length < count || cr.length < count) {
          throw const JpxException('JPEG 2000 sYCC chroma planes are shorter than the luma plane.');
        }
        for (var index = 0; index < count; index++) {
          converter.pixel(index, y[index], cb[index], cr[index]);
        }
      case '422':
        _sycc422(converter, y, cb, cr, width, height, chromaWidth, chromaHeight, x0);
      case '420':
        _sycc420(converter, y, cb, cr, width, height, chromaWidth, chromaHeight, x0, y0);
      default:
        throw JpxUnsupportedException('JPEG 2000 sYCC chroma layout $layout is not supported.');
    }
    return <TypedDataList<int>>[r, g, b];
  }

  /// `sycc422_to_rgb`: every chroma sample covers two luma columns; an
  /// odd image origin makes the first column use Cb = Cr = 0 and the
  /// reference's `j / 2 == comp12w` guard also yields 0 for a trailing
  /// column without a chroma sample.
  static void _sycc422(
    final _Sycc converter,
    final TypedDataList<int> y,
    final TypedDataList<int> cb,
    final TypedDataList<int> cr,
    final int maxw,
    final int maxh,
    final int comp12w,
    final int comp12h,
    final int x0,
  ) {
    final offx = x0 & 1;
    final loopmaxw = maxw - offx;
    final pairs = loopmaxw >> 1;
    final tail = loopmaxw & 1;
    final rowChroma = pairs + (tail != 0 && pairs < comp12w ? 1 : 0);
    final required = maxh * rowChroma;
    if (required > cb.length || required > cr.length || comp12h < maxh) {
      throw const JpxException('JPEG 2000 sYCC chroma planes are shorter than the luma plane.');
    }
    var ci = 0;
    var yi = 0;
    for (var i = 0; i < maxh; i++) {
      if (offx > 0) {
        converter.pixel(yi, y[yi], 0, 0);
        yi++;
      }
      for (var j = 0; j < pairs; j++) {
        converter.pixel(yi, y[yi], cb[ci], cr[ci]);
        yi++;
        converter.pixel(yi, y[yi], cb[ci], cr[ci]);
        yi++;
        ci++;
      }
      if (tail != 0) {
        if (pairs == comp12w) {
          converter.pixel(yi, y[yi], 0, 0);
        } else {
          converter.pixel(yi, y[yi], cb[ci], cr[ci]);
          ci++;
        }
        yi++;
      }
    }
  }

  /// `sycc420_to_rgb`: every chroma sample covers a 2x2 luma block; odd
  /// origins make the first column and first row use Cb = Cr = 0.
  static void _sycc420(
    final _Sycc converter,
    final TypedDataList<int> y,
    final TypedDataList<int> cb,
    final TypedDataList<int> cr,
    final int maxw,
    final int maxh,
    final int comp12w,
    final int comp12h,
    final int x0,
    final int y0,
  ) {
    final offx = x0 & 1;
    final offy = y0 & 1;
    final loopmaxw = maxw - offx;
    final loopmaxh = maxh - offy;
    final pairs = loopmaxw >> 1;
    final tail = loopmaxw & 1;
    final rowChroma = pairs + (tail != 0 && pairs < comp12w ? 1 : 0);
    final chromaRows = (loopmaxh + 1) >> 1;
    final required = chromaRows * rowChroma;
    if (required > cb.length || required > cr.length || comp12h < chromaRows) {
      throw const JpxException('JPEG 2000 sYCC chroma planes are shorter than the luma plane.');
    }
    var yi = 0;
    if (offy > 0) {
      for (var j = 0; j < maxw; j++) {
        converter.pixel(yi, y[yi], 0, 0);
        yi++;
      }
    }
    var ci = 0;
    var i = 0;
    for (; i + 1 < loopmaxh; i += 2) {
      var ny = yi + maxw;
      if (offx > 0) {
        converter.pixel(yi, y[yi], 0, 0);
        yi++;
        converter.pixel(ny, y[ny], cb[ci], cr[ci]);
        ny++;
      }
      for (var j = 0; j < pairs; j++) {
        converter.pixel(yi, y[yi], cb[ci], cr[ci]);
        yi++;
        converter.pixel(yi, y[yi], cb[ci], cr[ci]);
        yi++;
        converter.pixel(ny, y[ny], cb[ci], cr[ci]);
        ny++;
        converter.pixel(ny, y[ny], cb[ci], cr[ci]);
        ny++;
        ci++;
      }
      if (tail != 0) {
        if (pairs == comp12w) {
          converter.pixel(yi, y[yi], 0, 0);
          converter.pixel(ny, y[ny], 0, 0);
        } else {
          converter.pixel(yi, y[yi], cb[ci], cr[ci]);
          converter.pixel(ny, y[ny], cb[ci], cr[ci]);
          ci++;
        }
        yi++;
        ny++;
      }
      yi = ny;
    }
    if (i < loopmaxh) {
      if (offx > 0) {
        converter.pixel(yi, y[yi], 0, 0);
        yi++;
      }
      for (var j = 0; j < pairs; j++) {
        converter.pixel(yi, y[yi], cb[ci], cr[ci]);
        yi++;
        converter.pixel(yi, y[yi], cb[ci], cr[ci]);
        yi++;
        ci++;
      }
      if (tail != 0) {
        if (pairs == comp12w) {
          converter.pixel(yi, y[yi], 0, 0);
        } else {
          converter.pixel(yi, y[yi], cb[ci], cr[ci]);
        }
      }
    }
  }
}

/// `sycc_to_rgb` of OpenJPEG `color.c` with the arithmetic of the
/// pinned arm64 build: C `(int)` truncation toward zero on
/// `1.402 * cr`, `1.772 * cb` and the fused `0.344 * cb + 0.714 * cr`,
/// which clang contracts into `fma(0.344, cb, fl(0.714 * cr))`.
final class _Sycc {
  _Sycc(final int precision, this.r, this.g, this.b)
    : offset = 1 << (precision - 1),
      upb = (1 << precision) - 1;

  final int offset;
  final int upb;
  final TypedDataList<int> r;
  final TypedDataList<int> g;
  final TypedDataList<int> b;

  void pixel(final int index, final int y, final int cbValue, final int crValue) {
    final cb = cbValue - offset;
    final cr = crValue - offset;
    final red = y + (1.402 * cr).truncate();
    final green = y - _truncateFused(cb, cr);
    final blue = y + (1.772 * cb).truncate();
    r[index] = red < 0 ? 0 : (red > upb ? upb : red);
    g[index] = green < 0 ? 0 : (green > upb ? upb : green);
    b[index] = blue < 0 ? 0 : (blue > upb ? upb : blue);
  }

  /// `(int)fma(0.344, cb, 0.714 * cr)`. The plain double sum and the
  /// fused product differ by at most one unit in the last place, so the
  /// truncation can only change when the sum sits within that distance
  /// of an integer; only then is the fused result computed exactly.
  static int _truncateFused(final int cb, final int cr) {
    final right = 0.714 * cr;
    final plain = 0.344 * cb + right;
    final nearest = plain.roundToDouble();
    if ((plain - nearest).abs() > 1e-8) {
      return plain.truncate();
    }
    return _fma(0.344, cb.toDouble(), right).truncate();
  }

  /// Correctly rounded `a * b + c` (round to nearest, ties to even) with
  /// exact dyadic arithmetic; the inputs are finite doubles.
  static double _fma(final double a, final double b, final double c) {
    final (ma, ea) = _decompose(a);
    final (mb, eb) = _decompose(b);
    final (mc, ec) = _decompose(c);
    final product = ma * mb;
    final productExponent = ea + eb;
    final exponent = math.min(productExponent, ec);
    final sum = (product << (productExponent - exponent)) + (mc << (ec - exponent));
    if (sum == BigInt.zero) {
      return 0;
    }
    final negative = sum.isNegative;
    var magnitude = sum.abs();
    var shift = 0;
    final bits = magnitude.bitLength;
    if (bits > 53) {
      shift = bits - 53;
      final truncated = magnitude >> shift;
      final remainder = magnitude - (truncated << shift);
      final half = BigInt.one << (shift - 1);
      var rounded = truncated;
      if (remainder > half || (remainder == half && truncated.isOdd)) {
        rounded += BigInt.one;
      }
      magnitude = rounded;
    }
    final value = _scaleByPowerOfTwo(magnitude.toDouble(), exponent + shift);
    return negative ? -value : value;
  }

  /// `value * 2^exponent` by exact doublings/halvings (no `pow`, no
  /// shifts beyond 32 bits, so the VM and the compiled web build agree).
  static double _scaleByPowerOfTwo(final double value, final int exponent) {
    var result = value;
    if (exponent >= 0) {
      for (var step = 0; step < exponent; step++) {
        result *= 2;
      }
    } else {
      for (var step = 0; step > exponent; step--) {
        result /= 2;
      }
    }
    return result;
  }

  /// Splits a finite double into an integer mantissa and a power-of-two
  /// exponent such that `value == mantissa * 2^exponent`. The IEEE words
  /// are read as two 32-bit halves because dart2js has no 64-bit view.
  static (BigInt, int) _decompose(final double value) {
    if (value == 0) {
      return (BigInt.zero, 0);
    }
    final bits = ByteData(8)..setFloat64(0, value, Endian.big);
    final high = bits.getUint32(0, Endian.big);
    final low = bits.getUint32(4, Endian.big);
    final sign = (high >> 31) != 0;
    final biasedExponent = (high >> 20) & 0x7FF;
    final fraction = (high & 0xFFFFF) * 4294967296 + low;
    final (int mantissa, int exponent) = biasedExponent == 0
        ? (fraction, -1074)
        : (fraction + 4503599627370496, biasedExponent - 1075);
    final magnitude = BigInt.from(mantissa);
    return (sign ? -magnitude : magnitude, exponent);
  }
}
