import 'dart:typed_data';

import 'jpx_exception.dart';

/// Inverse multiple component transforms (ISO/IEC 15444-1 Annex G):
/// the reversible RCT on integer buffers and the irreversible ICT on
/// float32 buffers, with OpenJPEG's constant set and update order.
final class JpxMct {
  JpxMct._();

  /// Applies the inverse transform to exactly three [buffers] (Y, U,
  /// V component order in the codestream) in place. [irreversible]
  /// selects ICT; the buffers must then be Float32List.
  static void inverse(final List<TypedData> buffers, final bool irreversible) {
    if (buffers.length != 3) {
      throw const JpxException('The multiple component transform needs exactly three components.');
    }
    if (irreversible) {
      final y = buffers[0];
      final u = buffers[1];
      final v = buffers[2];
      if (y is! Float32List || u is! Float32List || v is! Float32List) {
        throw const JpxException('The irreversible transform needs float tile buffers.');
      }
      if (y.length != u.length || y.length != v.length) {
        throw const JpxException('The multiple component transform needs equal tile sizes.');
      }
      _inverseIct(y, u, v);
    } else {
      final y = buffers[0];
      final u = buffers[1];
      final v = buffers[2];
      if (y is! Int32List || u is! Int32List || v is! Int32List) {
        throw const JpxException('The reversible transform needs integer tile buffers.');
      }
      if (y.length != u.length || y.length != v.length) {
        throw const JpxException('The multiple component transform needs equal tile sizes.');
      }
      _inverseRct(y, u, v);
    }
  }

  /// OpenJPEG `opj_mct_decode`: g = y - ((u + v) >> 2); r = v + g;
  /// b = u + g.
  static void _inverseRct(final Int32List y, final Int32List u, final Int32List v) {
    final samples = y.length;
    for (var index = 0; index < samples; index++) {
      final valueY = y[index];
      final valueU = u[index];
      final valueV = v[index];
      final g = valueY - ((valueU + valueV) >> 2);
      y[index] = valueV + g;
      u[index] = g;
      v[index] = valueU + g;
    }
  }

  /// OpenJPEG `opj_mct_decode_real` scalar constants.
  static void _inverseIct(final Float32List y, final Float32List u, final Float32List v) {
    final samples = y.length;
    for (var index = 0; index < samples; index++) {
      final valueY = y[index];
      final valueU = u[index];
      final valueV = v[index];
      y[index] = _f32(valueY + valueV * 1.402);
      u[index] = _f32(valueY - valueU * 0.34413 - valueV * 0.71414);
      v[index] = _f32(valueY + valueU * 1.772);
    }
  }

  static double _f32(final double value) {
    final store = Float32List(1)..[0] = value;
    return store[0];
  }
}
