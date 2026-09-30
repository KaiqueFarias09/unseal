import 'dart:typed_data';

import 'djvu_exception.dart';
import 'zp_decoder.dart';

/// Largest block size a BZZ stream may declare. The format carries the value
/// in 24 bits and the encoder caps blocks at 4 MiB (DjVu 3 spec, appendix 4).
const int _maxBzzBlockSize = 4 * 1024 * 1024;

/// Default cap on the materialized output of one BZZ stream. Chunk callers
/// bound this with their own limits before decoding; the default keeps an
/// isolated decode from multiplying hostile block declarations.
const int bzzMaxOutputBytes = 8 * 1024 * 1024;

/// Synthetic end-of-stream bytes the arithmetic decoder may consume before a
/// stream is declared truncated. Valid streams finish inside the decoder's
/// look-ahead window.
const int _maxBzzSyntheticBytes = 16;

/// Contexts of one BZZ stream: the 262-entry MTF decision tree of the DjVu 3
/// specification (appendix 4). Contexts are shared by every block; they are
/// initialized once per stream and never reset.
const int _bzzContextCount = 262;

/// Decompresses a BZZ byte stream (DjVu 3 spec, appendix 4).
///
/// The stream is a sequence of blocks, each preceded by a 24-bit declared
/// block size in the arithmetic coder's passthrough mode. A declared size of
/// zero ends the stream. Every declared size is validated against the block
/// and output limits before its working buffers are allocated, so hostile
/// declarations fail with [DjvuException] without allocating output.
///
/// [truncatedMessage] is thrown when the arithmetic stream ends early.
/// [maxOutputBytes] bounds the concatenation of all blocks; chunk callers
/// pass their own chunk-specific bounds.
Uint8List decodeDjvuBzz(
  final Uint8List encoded, {
  required final String truncatedMessage,
  final int maxOutputBytes = bzzMaxOutputBytes,
}) {
  if (maxOutputBytes < 0) {
    throw const DjvuException('DjVu BZZ output limit is invalid.');
  }
  final zp = DjvuZpDecoder(encoded, truncatedMessage: truncatedMessage);
  final contexts = Uint8List(_bzzContextCount);
  var produced = 0;
  final blocks = <Uint8List>[];
  while (true) {
    final declaredSize = _decodeRaw(zp, 24);
    if (declaredSize == 0) break;
    if (declaredSize > _maxBzzBlockSize) {
      throw const DjvuException('DjVu BZZ block exceeds the 4 MiB declared-size limit.');
    }
    if (declaredSize > maxOutputBytes - produced) {
      throw const DjvuException('DjVu BZZ stream exceeds its output limit.');
    }
    final block = _decodeBlock(zp, contexts, declaredSize, truncatedMessage);
    blocks.add(block);
    produced += block.length;
  }

  final output = Uint8List(produced);
  var offset = 0;
  for (final block in blocks) {
    output.setRange(offset, offset + block.length, block);
    offset += block.length;
  }
  return output;
}

/// Decodes a b-bit integer in the passthrough mode: the value arrives
/// most-significant-bit first with an implicit leading one.
int _decodeRaw(final DjvuZpDecoder zp, final int bits) {
  var value = 1;
  var remaining = bits;
  while (remaining > 0) {
    value = (value << 1) | (zp.decodePassthroughBzz() ? 1 : 0);
    remaining--;
  }
  return value - (1 << bits);
}

/// Decodes one BZZ block of [blockSize] symbols into its BWT-decoded bytes.
Uint8List _decodeBlock(
  final DjvuZpDecoder zp,
  final Uint8List contexts,
  final int blockSize,
  final String truncatedMessage,
) {
  // Estimation speed: two passthrough bits encode fshift in {0, 1, 2}.
  var fshift = 0;
  if (zp.decodePassthroughBzz()) {
    fshift++;
    if (zp.decodePassthroughBzz()) fshift++;
  }

  final mtf = Uint8List(256);
  for (var index = 0; index < 256; index++) {
    mtf[index] = index;
  }
  final freq = Uint32List(4);
  var fadd = 4;
  var lastMtfNo = 3;
  var markerPosition = -1;
  final data = Uint8List(blockSize);

  for (var index = 0; index < blockSize; index++) {
    if ((index & 0x3FF) == 0 && zp.syntheticBytes > _maxBzzSyntheticBytes) {
      throw DjvuException(truncatedMessage);
    }
    final mtfNo = _decodeMtfNumber(zp, contexts, lastMtfNo);
    lastMtfNo = mtfNo;
    if (mtfNo == 256) {
      // End-of-block marker: stored as a zero byte, positioned, and excluded
      // from the MTF update.
      data[index] = 0;
      markerPosition = index;
      continue;
    }
    final symbol = mtf[mtfNo];
    data[index] = symbol;

    fadd += fadd >> fshift;
    if (fadd > 0x10000000) {
      fadd >>= 24;
      for (var slot = 0; slot < 4; slot++) {
        freq[slot] >>= 24;
      }
    }
    final combinedFreq = mtfNo < 4 ? fadd + freq[mtfNo] : fadd;

    // Rotate the symbol towards the front. Symbols beyond the frequency slots
    // first move down to slot 3; frequency ordering then moves it further left.
    var slot = mtfNo;
    if (slot > 3) {
      for (var index2 = mtfNo; index2 > 3; index2--) {
        mtf[index2] = mtf[index2 - 1];
      }
      slot = 3;
    }
    while (slot > 0 && combinedFreq >= freq[slot - 1]) {
      mtf[slot] = mtf[slot - 1];
      freq[slot] = freq[slot - 1];
      slot--;
    }
    mtf[slot] = symbol;
    freq[slot] = combinedFreq;
  }

  if (markerPosition < 0) {
    throw const DjvuException('DjVu BZZ block has no end-of-block marker.');
  }
  if (markerPosition == 0) {
    // The threading walk starts at the first position, which must be a data
    // byte (DjVu 3 spec, appendix 4: markerpos > 0 and < blocksize).
    throw const DjvuException('DjVu BZZ block marker position is invalid.');
  }
  _inverseBurrowsWheeler(data, markerPosition);
  // The threading writes the decoded bytes at data[0 .. blockSize - 2]; the
  // final slot is not part of the output.
  final output = Uint8List(blockSize - 1);
  output.setRange(0, blockSize - 1, data);
  return output;
}

/// Decodes one MTF index through the 262-context decision tree. The first two
/// levels reuse the context selected by the previous index (0 or 1 keep their
/// own context; anything larger uses the third).
int _decodeMtfNumber(final DjvuZpDecoder zp, final Uint8List contexts, final int lastMtfNo) {
  final reuseContext = lastMtfNo < 2 ? lastMtfNo : 2;
  if (_decodeContextBit(zp, contexts, reuseContext)) return 0;
  if (_decodeContextBit(zp, contexts, 3 + reuseContext)) return 1;
  if (_decodeContextBit(zp, contexts, 6)) return 2 + _decodeBinary(zp, contexts, 7, 1);
  if (_decodeContextBit(zp, contexts, 8)) return 4 + _decodeBinary(zp, contexts, 9, 2);
  if (_decodeContextBit(zp, contexts, 12)) return 8 + _decodeBinary(zp, contexts, 13, 3);
  if (_decodeContextBit(zp, contexts, 20)) return 16 + _decodeBinary(zp, contexts, 21, 4);
  if (_decodeContextBit(zp, contexts, 36)) return 32 + _decodeBinary(zp, contexts, 37, 5);
  if (_decodeContextBit(zp, contexts, 68)) return 64 + _decodeBinary(zp, contexts, 69, 6);
  if (_decodeContextBit(zp, contexts, 132)) return 128 + _decodeBinary(zp, contexts, 133, 7);
  return 256;
}

bool _decodeContextBit(final DjvuZpDecoder zp, final Uint8List contexts, final int index) {
  final decoded = zp.decodeBit(contexts[index]);
  contexts[index] = decoded.state;
  return decoded.bit;
}

/// Decodes a [bits]-bit binary number from the sub-tree rooted at
/// `contexts[base - 1]`.
int _decodeBinary(
  final DjvuZpDecoder zp,
  final Uint8List contexts,
  final int base,
  final int bits,
) {
  final subtree = base - 1;
  var value = 1;
  var remaining = bits;
  while (remaining > 0) {
    value = (value << 1) | (_decodeContextBit(zp, contexts, subtree + value) ? 1 : 0);
    remaining--;
  }
  return value - (1 << bits);
}

/// Threaded inverse Burrows-Wheeler transform, in place on the block.
///
/// The marker byte at [markerPosition] is excluded from the threading: the
/// sorted order reserves slot 0 for it and the walk drops it, leaving
/// `blockSize - 1` decoded bytes.
void _inverseBurrowsWheeler(final Uint8List data, final int markerPosition) {
  final blockSize = data.length;
  final counts = Uint32List(256);
  for (var index = 0; index < blockSize; index++) {
    if (index != markerPosition) counts[data[index]]++;
  }
  final sortedStart = Uint32List(256);
  var running = 1; // Sorted slot 0 belongs to the dropped marker.
  for (var symbol = 0; symbol < 256; symbol++) {
    sortedStart[symbol] = running;
    running += counts[symbol];
  }

  final ranks = Uint32List(blockSize);
  final seen = Uint32List(256);
  for (var index = 0; index < blockSize; index++) {
    if (index == markerPosition) continue;
    final symbol = data[index];
    ranks[index] = (symbol << 24) | (seen[symbol] & 0x00FFFFFF);
    seen[symbol]++;
  }

  var follow = 0;
  var last = blockSize - 1;
  while (last > 0) {
    last--;
    final rank = ranks[follow];
    final symbol = (rank >> 24) & 0xFF;
    data[last] = symbol;
    follow = sortedStart[symbol] + (rank & 0x00FFFFFF);
  }
}
