import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../exceptions/pdf_exception.dart';
import '../header/pdf_object.dart';
import 'ccitt/ccitt_decoder.dart';
import 'jbig2/jbig2_decoder.dart';

/// Applies a stream's `/Filter` chain (and `/DecodeParms` predictors)
/// to its raw bytes.
///
/// [resolve] follows indirect references inside the filter entries —
/// the cross-reference entries needed for that must already be known
/// to the caller, which holds for every stream read through
/// `PdfDocument` (filter entries must be direct per the spec, but
/// enough real files indirect them that the hook pays for itself).
///
/// Unsupported filters (the image codecs) throw [PdfException];
/// callers degrade per-object instead of failing the document.
Uint8List decodePdfStream(
  final PdfStream stream,
  final PdfObject? Function(PdfObject object) resolve,
) {
  var data = stream.bytes;
  final filterObject = resolve(stream.dictionary['Filter'] ?? const PdfNull());
  final parmsObject = resolve(
    stream.dictionary['DecodeParms'] ?? stream.dictionary['DP'] ?? const PdfNull(),
  );
  if (filterObject is PdfNull || filterObject == null) return data;

  final names = filterObject is PdfName
      ? <PdfObject>[filterObject]
      : filterObject is PdfArray
      ? filterObject.items
      : const <PdfObject>[];
  final parms = parmsObject is PdfDictionary
      ? <PdfObject?>[parmsObject]
      : parmsObject is PdfArray
      ? parmsObject.items
      : <PdfObject?>[const PdfNull()];
  for (var index = 0; index < names.length; index++) {
    final name = names[index];
    if (name is! PdfName) continue;

    final parm = parms.length > index ? parms[index] : const PdfNull();

    switch (name.value) {
      case 'FlateDecode':
        data = _inflate(data);
        data = _unpredict(data, parm, resolve);
      case 'LZWDecode':
        data = _lzwDecode(data, parm, resolve);
        data = _unpredict(data, parm, resolve);
      case 'ASCIIHexDecode':
        data = _asciiHexDecode(data);
      case 'ASCII85Decode':
        data = _ascii85Decode(data);
      case 'RunLengthDecode':
        data = _runLengthDecode(data);
      case 'CCITTFaxDecode':
        data = decodeCcittFax(data, parm, resolve);
      case 'JBIG2Decode':
        data = decodeJbig2(data, globals: _jbig2Globals(parm, resolve));
      default:
        throw PdfException('PDF stream filter /${name.value} is not supported.');
    }
  }

  return data;
}

/// Resolves the `/JBIG2Globals` reference in the decode parameters
/// to the referenced stream's bytes (null when absent).
Uint8List? _jbig2Globals(
  final PdfObject? parm,
  final PdfObject? Function(PdfObject object) resolve,
) {
  if (parm is! PdfDictionary) return null;
  final stream = resolve(parm['JBIG2Globals'] ?? const PdfNull());
  if (stream is PdfStream) return decodePdfStream(stream, resolve);

  return null;
}

Uint8List _inflate(final Uint8List data) {
  try {
    return Uint8List.fromList(const ZLibDecoder().decodeBytes(data));
  } on FormatException catch (error) {
    throw PdfException('FlateDecode failed: ${error.message}');
  }
}

/// Expands an LZW-compressed stream (PDF 32000-1:2008 §7.4.4.2).
///
/// The dictionary starts with the 256 literals plus the clear (256)
/// and end-of-data (257) codes; codes are packed big-endian and grow
/// from 9 to at most 12 bits as entries are added toward the 4096
/// cap. `/EarlyChange` (default 1) shifts each width bump one code
/// early — the width flips at 511/1023/2047 entries instead of
/// 512/1024/2048. A missing end-of-data marker simply stops at the
/// payload's end; a code outside the dictionary is a [PdfException].
/// Predictor parameters apply after the expansion, as with Flate.
Uint8List _lzwDecode(
  final Uint8List data,
  final PdfObject? parm,
  final PdfObject? Function(PdfObject object) resolve,
) {
  var earlyChange = 1;
  if (parm is PdfDictionary) {
    final explicit = _intValue(resolve(parm['EarlyChange'] ?? const PdfNull()));
    if (explicit != null && explicit == 0) earlyChange = 0;
  }

  final table = List<Uint8List?>.filled(4096, null);
  for (var i = 0; i < 256; i++) {
    table[i] = Uint8List(1)..[0] = i;
  }
  var nextEntry = 258;
  var width = 9;
  Uint8List? previous;

  final out = BytesBuilder(copy: false);
  var bitBuffer = 0;
  var bitCount = 0;
  var cursor = 0;
  while (true) {
    while (bitCount < width) {
      if (cursor >= data.length) return out.toBytes();
      bitBuffer = (bitBuffer << 8) | data[cursor++];
      bitCount += 8;
    }
    bitCount -= width;
    final code = (bitBuffer >> bitCount) & ((1 << width) - 1);
    bitBuffer &= (1 << bitCount) - 1;

    if (code == 257) break; // EOD
    if (code == 256) {
      // Clear: reset the dictionary and the code width.
      nextEntry = 258;
      width = 9;
      previous = null;

      continue;
    }

    Uint8List entry;
    if (code < nextEntry) {
      entry = table[code]!;
    } else if (code == nextEntry && previous != null) {
      // The KwKwK case: the entry being defined right now.
      entry = Uint8List(previous.length + 1)
        ..setRange(0, previous.length, previous)
        ..[previous.length] = previous[0];
    } else {
      throw const PdfException('LZWDecode hit a code outside the dictionary.');
    }
    out.add(entry);

    if (previous != null && nextEntry < 4096) {
      table[nextEntry++] = Uint8List(previous.length + 1)
        ..setRange(0, previous.length, previous)
        ..[previous.length] = entry[0];
      if (nextEntry + earlyChange == 512) {
        width = 10;
      } else if (nextEntry + earlyChange == 1024) {
        width = 11;
      } else if (nextEntry + earlyChange == 2048) {
        width = 12;
      }
    }
    previous = entry;
  }

  return out.toBytes();
}

/// Undoes `/Predictor` cross-row filters (the PNG family, 10-15, and
/// TIFF 2) over an inflated stream — required by many cross-reference
/// streams and LZW/Flate image data.
Uint8List _unpredict(
  final Uint8List data,
  final PdfObject? parm,
  final PdfObject? Function(PdfObject object) resolve,
) {
  if (parm is! PdfDictionary) return data;
  final predictor = _intValue(resolve(parm['Predictor'] ?? const PdfNull()));
  if (predictor == null || predictor < 2) return data;

  final columns = _intValue(resolve(parm['Columns'] ?? const PdfNull())) ?? 1;
  final colors = _intValue(resolve(parm['Colors'] ?? const PdfNull())) ?? 1;
  final bitsPerComponent = _intValue(resolve(parm['BitsPerComponent'] ?? const PdfNull())) ?? 8;

  if (predictor == 2) return _tiffPredictor(data, columns, colors, bitsPerComponent);

  return _pngPredictor(data, columns, colors, bitsPerComponent);
}

Uint8List _tiffPredictor(
  final Uint8List data,
  final int columns,
  final int colors,
  final int bitsPerComponent,
) {
  if (bitsPerComponent != 8) return data;

  final out = Uint8List.fromList(data);
  final rowLength = columns * colors;
  for (var row = 0; row * rowLength < out.length; row++) {
    final base = row * rowLength;
    for (var i = colors; i < rowLength; i++) {
      out[base + i] = (out[base + i] + out[base + i - colors]) & 0xFF;
    }
  }

  return out;
}

Uint8List _pngPredictor(
  final Uint8List data,
  final int columns,
  final int colors,
  final int bitsPerComponent,
) {
  final bitsPerPixel = colors * bitsPerComponent;
  final bytesPerPixel = (bitsPerPixel + 7) >> 3;
  final rowLength = (columns * bitsPerPixel + 7) >> 3;
  if (rowLength == 0) return data;

  final rows = data.length ~/ (rowLength + 1);
  final out = Uint8List(rows * rowLength);
  final previous = Uint8List(rowLength);
  for (var row = 0; row < rows; row++) {
    final base = row * (rowLength + 1);
    final filterType = data[base];
    final inputOffset = base + 1;
    final outputOffset = row * rowLength;
    for (var i = 0; i < rowLength; i++) {
      final raw = data[inputOffset + i];
      final left = i >= bytesPerPixel ? out[outputOffset + i - bytesPerPixel] : 0;
      final up = previous[i];
      final upLeft = i >= bytesPerPixel ? previous[i - bytesPerPixel] : 0;
      var value = raw;
      switch (filterType) {
        case 0:
          value = raw;
        case 1:
          value = raw + left;
        case 2:
          value = raw + up;
        case 3:
          value = raw + ((left + up) >> 1);
        case 4:
          final p = left + up - upLeft;
          final pa = (p - left).abs();
          final pb = (p - up).abs();
          final pc = (p - upLeft).abs();
          value =
              raw +
              (pa <= pb && pa <= pc
                  ? left
                  : pb <= pc
                  ? up
                  : upLeft);
        default:
          value = raw;
      }
      out[outputOffset + i] = value & 0xFF;
    }
    previous.setRange(0, rowLength, out, outputOffset);
  }

  return out;
}

Uint8List _asciiHexDecode(final Uint8List data) {
  final out = BytesBuilder(copy: false);
  var pending = -1;
  for (final byte in data) {
    if (byte == 0x3E) break; // >
    final value = _hexDigit(byte);
    if (value == null) continue;
    if (pending < 0) {
      pending = value;
    } else {
      out.addByte(pending * 16 + value);
      pending = -1;
    }
  }
  if (pending >= 0) out.addByte(pending * 16);

  return out.toBytes();
}

Uint8List _ascii85Decode(final Uint8List data) {
  final out = BytesBuilder(copy: false);
  final group = List<int>.filled(5, 0);
  var count = 0;
  var i = 0;
  if (data.length >= 2 && data[0] == 0x3C && data[1] == 0x7E) i = 2; // <~
  for (; i < data.length; i++) {
    final byte = data[i];
    if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) continue;
    if (byte == 0x7E) break; // ~ (the > follows)
    if (byte == 0x7A) {
      // z: four zero bytes, only valid as a whole group.
      if (count != 0) throw const PdfException('ASCII85Decode hit z inside a group.');
      out.add([0, 0, 0, 0]);
      continue;
    }
    if (byte < 0x21 || byte > 0x75) {
      throw const PdfException('ASCII85Decode hit an invalid character.');
    }
    group[count++] = byte - 0x21;
    if (count == 5) {
      var value = 0;
      for (final digit in group) {
        value = value * 85 + digit;
      }
      out.add([(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]);
      count = 0;
    }
  }
  if (count > 0) {
    // Final partial group: pad with u (84) and emit count - 1 bytes.
    for (var k = count; k < 5; k++) {
      group[k] = 84;
    }

    var value = 0;
    for (final digit in group) {
      value = value * 85 + digit;
    }

    final full = [(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF];
    out.add(full.sublist(0, count - 1));
  }

  return out.toBytes();
}

Uint8List _runLengthDecode(final Uint8List data) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < data.length) {
    final length = data[i++];
    if (length == 128) break; // EOD
    if (length < 128) {
      final end = i + length + 1;
      if (end > data.length) break;
      out.add(Uint8List.sublistView(data, i, end));
      i = end;
    } else {
      if (i >= data.length) break;
      final byte = data[i++];
      final repeat = 257 - length;
      out.add(List<int>.filled(repeat, byte));
    }
  }

  return out.toBytes();
}

int? _intValue(final PdfObject? object) {
  final resolved = object;
  if (resolved is PdfNumber) return resolved.intValue;

  return null;
}

int? _hexDigit(final int byte) {
  if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
  if (byte >= 0x41 && byte <= 0x46) return byte - 0x41 + 10;
  if (byte >= 0x61 && byte <= 0x66) return byte - 0x61 + 10;

  return null;
}
