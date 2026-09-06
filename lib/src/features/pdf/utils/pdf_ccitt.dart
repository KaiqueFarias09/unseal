import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import '../header/pdf_object.dart';

/// Decodes a CCITTFaxDecode payload (ITU-T T.4/T.6 fax coding) into
/// packed 1-bit rows: most significant bit first, `1` = black, rows
/// padded to whole bytes — the input contract documented on
/// `PdfBitmap` (utils/pdf_bitmap.dart).
///
/// Parameters come from the stream's `/DecodeParms`: `/K` selects
/// the coding (0 = Group 3 1D, < 0 = Group 3 2D, > 0 = Group 4)
/// alongside `/Columns`, `/Rows`, `/BlackIs1`, `/EncodedByteAlign`,
/// `/EndOfLine`, `/EndOfBlock` and `/DamagedRowsBeforeError`. The
/// decoder normalizes all of them, including the `/Decode`
/// inversion, so callers always receive black-as-1 rows.
///
/// Ground truth: pdf.js v3.11.174 `src/core/ccitt.js`
/// (`CcittFaxDecoder`). Port with parity comments pointing at it.
Uint8List decodeCcittFax(
  final Uint8List data,
  final PdfObject? parm,
  final PdfObject? Function(PdfObject object) resolve,
) {
  throw const PdfException('CCITTFaxDecode is not implemented yet.');
}
