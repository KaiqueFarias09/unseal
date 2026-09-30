import 'dart:typed_data';

import '../../../../foundation/images/ccitt/ccitt_fax_decoder.dart';
import '../../exceptions/pdf_exception.dart';
import '../../header/pdf_object.dart';

/// Decodes a CCITTFaxDecode payload (ITU-T T.4/T.6 fax coding) into
/// packed 1-bit rows: most significant bit first, `1` = black, rows
/// padded to whole bytes — the input contract documented on
/// `PdfBitmap` (image/pdf_bitmap.dart).
///
/// Parameters come from the stream's `/DecodeParms`: `/K` selects
/// the coding (0 = Group 3 1D, < 0 = Group 4, > 0 = Group 3 2D)
/// alongside `/Columns`, `/Rows`, `/BlackIs1`, `/EncodedByteAlign`,
/// `/EndOfLine` and `/EndOfBlock`. Like
/// pdf.js, the `/BlackIs1` flag and a `/Decode [1 0]` array flip the
/// sample polarity inside the decoder, so callers always receive
/// rows in the default `/Decode [0 1]` convention (0 = black).
///
/// The bit-level decoder core lives in
/// `foundation/images/ccitt/ccitt_fax_decoder.dart` and is shared
/// with the TIFF CCITT pages and the JBIG2 MMR decoder; this adapter
/// owns the PDF parameter mapping and keeps failures as
/// [PdfException].
Uint8List decodeCcittFax(
  final Uint8List data,
  final PdfObject? parm,
  final PdfObject? Function(PdfObject object) resolve,
) {
  var k = 0;
  var columns = 1728;
  var rows = 0;
  var endOfLine = false;
  var encodedByteAlign = false;
  var endOfBlock = true;
  var blackIs1 = false;
  var decodeInverts = false;

  if (parm is PdfDictionary) {
    k = _intValue(resolve(parm['K'] ?? const PdfNull()), fallback: 0);
    columns = _intValue(resolve(parm['Columns'] ?? const PdfNull()), fallback: 1728);
    rows = _intValue(resolve(parm['Rows'] ?? const PdfNull()), fallback: 0);
    endOfLine = _boolValue(resolve(parm['EndOfLine'] ?? const PdfNull()));
    encodedByteAlign = _boolValue(resolve(parm['EncodedByteAlign'] ?? const PdfNull()));
    final endOfBlockValue = resolve(parm['EndOfBlock'] ?? const PdfNull());
    if (endOfBlockValue is PdfBool) endOfBlock = endOfBlockValue.value;
    blackIs1 = _boolValue(resolve(parm['BlackIs1'] ?? const PdfNull()));
    final decode = resolve(parm['Decode'] ?? const PdfNull());
    if (decode is PdfArray && decode.items.length >= 2) {
      final low = resolve(decode.items[0]);
      final high = resolve(decode.items[1]);
      if (low is PdfNumber && high is PdfNumber) {
        // `[1 0]` inverts: sample 1 (black) must map to gray 0.
        decodeInverts = !(low.value == 0 && high.value == 1);
      }
    }
  }
  if (columns <= 0) columns = 1728;
  if (columns > ccittMaxColumns || rows > ccittMaxRows) {
    throw PdfException('CCITTFaxDecode geometry out of range: ${columns}x$rows.');
  }

  try {
    return decodeCcittFaxBytes(
      data,
      CcittFaxOptions(
        encoding: k,
        columns: columns,
        rows: rows,
        endOfLine: endOfLine,
        byteAlign: encodedByteAlign,
        endOfBlock: endOfBlock,
        blackIs1: blackIs1 || decodeInverts,
      ),
    );
  } on CcittFaxException catch (error) {
    throw PdfException(
      error.message
          .replaceFirst('CCITT fax geometry', 'CCITTFaxDecode geometry')
          .replaceFirst('CCITT fax output', 'CCITTFaxDecode output'),
    );
  }
}

/// `/K` fallback and `/Columns` coercion: integers pass through,
/// reals truncate, anything else falls back.
int _intValue(final PdfObject? object, {required final int fallback}) {
  final value = object;
  if (value is PdfNumber) return value.value.toInt();

  return fallback;
}

/// `/EndOfLine`-style boolean parameter: only an explicit `true`
/// enables the behavior.
bool _boolValue(final PdfObject? object) => object is PdfBool && object.value;
