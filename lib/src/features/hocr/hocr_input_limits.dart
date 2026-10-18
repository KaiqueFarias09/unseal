import 'hocr_exception.dart';

/// Rejects oversized source data before decoding or copying it to a worker.
void checkHocrInputLength(final int length) {
  if (length > 32 * 1024 * 1024) {
    throw const HocrException('hOCR input exceeds the 32 MiB limit.');
  }
}
