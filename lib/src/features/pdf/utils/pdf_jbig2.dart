import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';

/// Decodes a JBIG2Decode payload (ITU-T T.88, the embedded
/// segment format PDFs use — no file header) into packed 1-bit
/// rows: most significant bit first, `1` = black, rows padded to
/// whole bytes — the input contract documented on `PdfBitmap`
/// (utils/pdf_bitmap.dart).
///
/// [globals] carries the resolved bytes of the `/JBIG2Globals`
/// stream (retained symbol and pattern dictionaries shared across
/// pages) when the image references one.
///
/// Ground truth: pdf.js v3.11.174 `src/core/jbig2.js`
/// (`Jbig2Image`). Port with parity comments pointing at it.
Uint8List decodeJbig2(final Uint8List data, {final Uint8List? globals}) {
  throw const PdfException('JBIG2Decode is not implemented yet.');
}
