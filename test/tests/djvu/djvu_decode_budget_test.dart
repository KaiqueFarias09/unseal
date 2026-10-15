import 'package:test/test.dart';
import 'package:unseal/src/features/djvu/djvu_decode_budget.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('caps cumulative decoded page pixels across a DjVu document', () {
    final budget = DjvuDecodeBudget();
    budget.reserve(pixels: djvuMaxDecodedPixelsPerBook - 1, rasterBytes: 0);

    expect(
      () => budget.reserve(pixels: 2, rasterBytes: 0),
      throwsA(
        isA<DjvuException>().having(
          (error) => error.message,
          'message',
          contains('2048-megapixel'),
        ),
      ),
    );
  });

  test('caps cumulative materialized raster bytes across a DjVu document', () {
    final budget = DjvuDecodeBudget();
    budget.reserve(pixels: 0, rasterBytes: djvuMaxDecodedRasterBytesPerBook - 1);

    expect(
      () => budget.reserve(pixels: 0, rasterBytes: 2),
      throwsA(isA<DjvuException>().having((error) => error.message, 'message', contains('1 GiB'))),
    );
  });

  test('rejects invalid budget reservations with a typed DjVu failure', () {
    expect(
      () => DjvuDecodeBudget().reserve(pixels: -1, rasterBytes: 1),
      throwsA(isA<DjvuException>()),
    );
  });
}
