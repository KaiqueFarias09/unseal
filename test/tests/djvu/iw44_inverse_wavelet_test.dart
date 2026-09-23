import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/djvu/iw44_inverse_wavelet.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('reconstructs one sample and normalizes signed Q6 to a byte', () {
    final coefficients = Int16List(32 * 32)..[0] = 4096;

    expect(reconstructDjvuIw44Plane(coefficients, width: 1, height: 1), equals([192]));
    expect(coefficients[0], 4096, reason: 'the caller-owned input is preserved');
  });

  test('interpolates a bottom-edge sample vertically and returns top-down rows', () {
    final coefficients = Int16List(32 * 32)..[2 * 32] = 4096;

    expect(reconstructDjvuIw44Plane(coefficients, width: 1, height: 3), equals([174, 142, 110]));
  });

  test('interpolates a right-edge sample horizontally', () {
    final coefficients = Int16List(32 * 32)..[2] = 4096;

    expect(reconstructDjvuIw44Plane(coefficients, width: 3, height: 1), equals([110, 142, 174]));
  });

  test('runs both axes and all resolution levels for a corner impulse', () {
    final coefficients = Int16List(32 * 32)..[2 * 32 + 2] = 4096;

    expect(
      reconstructDjvuIw44Plane(coefficients, width: 3, height: 3),
      equals([115, 138, 161, 124, 131, 138, 133, 124, 115]),
    );
  });

  test('ignores coefficient padding outside the declared image', () {
    final coefficients = Int16List(32 * 32)
      ..[0] = 64
      ..[31 * 32 + 31] = 32767;

    expect(reconstructDjvuIw44Plane(coefficients, width: 1, height: 1), equals([129]));
  });

  test('clamps normalized samples at both byte limits', () {
    final high = Int16List(32 * 32)..[0] = 32767;
    final low = Int16List(32 * 32)..[0] = -32768;

    expect(reconstructDjvuIw44Plane(high, width: 1, height: 1), equals([255]));
    expect(reconstructDjvuIw44Plane(low, width: 1, height: 1), equals([0]));
  });

  test('rejects invalid dimensions and inconsistent padded coefficient buffers', () {
    expect(
      () => reconstructDjvuIw44Plane(Int16List(32 * 32), width: 0, height: 1),
      throwsA(isA<DjvuException>()),
    );
    expect(
      () => reconstructDjvuIw44Plane(Int16List(0), width: 2, height: 1),
      throwsA(isA<DjvuException>()),
    );
  });

  test('rejects a padded plane over the per-component cap before allocating output', () {
    expect(
      () => reconstructDjvuIw44Plane(Int16List(0), width: 3999, height: 4001),
      throwsA(isA<DjvuException>()),
    );
    expect(djvuMaxIw44PlaneSamples, 16 * 1000 * 1000);
  });
}
