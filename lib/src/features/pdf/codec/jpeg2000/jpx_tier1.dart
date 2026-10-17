import 'dart:typed_data';

import 'jpx_exception.dart';
import 'jpx_mq.dart';

/// Code-block style flags from COD/COC `SPcod`/`SPcoc` beyond the
/// bypass flag that lives in `jpx_limits.dart`.
const int kJpxCblkStyleReset = 0x02;

/// SPcod flag 0x02: MQ contexts reset between coding passes.
const int kJpxCblkStyleTerminate = 0x04;

/// SPcod flag 0x04: every MQ segment terminates.
const int kJpxCblkStyleVsc = 0x08;

/// SPcod flag 0x08: vertical stripe causal contexts.
const int kJpxCblkStyleSegmentation = 0x20;

/// SPcod flag 0x20: an expected segmentation symbol follows each
/// cleanup pass.

/// Context numbers: sign coding starts at 9, the aggregation context
/// is 17 and the uniform context is 18.
const int _ctxSc = 9;
const int _ctxAgg = 17;
const int _ctxUni = 18;

/// One decoded tier-1 segment: the sub-range of code-block data plus
/// the number of coding passes tier 2 read for it.
final class JpxSegment {
  /// Builds one segment over [offset]..[offset]+[length] carrying
  /// [passes] coding passes.
  const JpxSegment(this.offset, this.length, this.passes);

  /// Offset of the segment inside the merged code-block buffer.
  final int offset;

  /// Segment byte count.
  final int length;

  /// Coding passes packed into the segment.
  final int passes;
}

/// ZC context labels for the neighbour-significance byte
/// `0ddd vv hh` (diagonal, vertical, horizontal sums); tables D-1 of
/// ISO/IEC 15444-1 shared by the LL/LH, HL and HH orientations.
const List<int> _kLlLhLabels = <int>[
  0, 5, 8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, //
  1, 6, 8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, //
  2, 6, 8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, //
  2, 6, 8, 0, 3, 7, 8, 0, 4, 7, 8, 0, 0, 0, 0, 0, //
  2, 6, 8, 0, 3, 7, 8, 0, 4, 7, 8, //
];
const List<int> _kHlLabels = <int>[
  0, 3, 4, 0, 5, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, //
  1, 3, 4, 0, 6, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, //
  2, 3, 4, 0, 6, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, //
  2, 3, 4, 0, 6, 7, 7, 0, 8, 8, 8, 0, 0, 0, 0, 0, //
  2, 3, 4, 0, 6, 7, 7, 0, 8, 8, 8, //
];
const List<int> _kHhLabels = <int>[
  0, 1, 2, 0, 1, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 0, //
  3, 4, 5, 0, 4, 5, 5, 0, 5, 5, 5, 0, 0, 0, 0, 0, //
  6, 7, 7, 0, 7, 7, 7, 0, 7, 7, 7, 0, 0, 0, 0, 0, //
  8, 8, 8, 0, 8, 8, 8, 0, 8, 8, 8, 0, 0, 0, 0, 0, //
  8, 8, 8, 0, 8, 8, 8, 0, 8, 8, 8, //
];

/// Sub-band orientation: 0 = LL, 1 = HL, 2 = LH, 3 = HH.
const List<List<int>> _kLabelTables = <List<int>>[
  _kLlLhLabels,
  _kHlLabels,
  _kLlLhLabels,
  _kHhLabels,
];

/// Decodes JPEG 2000 tier-1 code-blocks: the significance, magnitude
/// refinement and cleanup passes over MQ or raw (bypass) segments,
/// with stripe-causal contexts, per-pass context reset, segmentation
/// symbols and ROI shifts.
final class JpxTier1 {
  JpxTier1._();

  /// Decodes [segments] (contiguous sub-ranges of [data]) for a
  /// code-block of [width] x [height] in band [orientation], [numbps]
  /// magnitude bit-planes, style [cblkStyle] and ROI shift [roiShift].
  ///
  /// Returns coefficients in the codec's 2x convention (OpenJPEG
  /// semantics: reversible callers halve them, irreversible callers
  /// scale by the quantization step size).
  static Int32List decodeCblk({
    required final Uint8List data,
    required final List<JpxSegment> segments,
    required final int width,
    required final int height,
    required final int orientation,
    required final int numbps,
    required final int cblkStyle,
    required final int roiShift,
  }) {
    if (width <= 0 || height <= 0 || width * height > 4096) {
      throw const JpxException('JPEG 2000 code-block geometry is invalid.');
    }
    final count = width * height;
    final magnitude = Int32List(count);
    final sign = Uint8List(count);
    final neighbors = Uint8List(count);
    final processing = Uint8List(count);

    var bpnoPlusOne = roiShift + numbps;
    if (bpnoPlusOne >= 31) {
      throw const JpxException('JPEG 2000 code-block declares too many bit-planes.');
    }
    var passtype = 2;

    final vsc = cblkStyle & kJpxCblkStyleVsc;
    // Context states initialize once per code-block and carry across
    // segment boundaries (OpenJPEG resets before the segment loop).
    final contextState = JpxMqDecoder.freshContextState();
    for (final segment in segments) {
      if (segment.length < 0 || segment.offset + segment.length > data.length) {
        throw const JpxException('Code-block segment escapes the codestream.');
      }
      if (segment.passes == 0) {
        continue;
      }
      final mq = JpxMqDecoder(data, segment.offset, segment.length, contextState: contextState);
      var remaining = segment.passes;
      while (remaining > 0 && bpnoPlusOne >= 1) {
        switch (passtype) {
          case 0:
            _significancePass(
              magnitude,
              sign,
              neighbors,
              processing,
              mq,
              width,
              height,
              bpnoPlusOne,
              orientation,
              vsc,
              false,
            );
          case 1:
            _refinementPass(
              magnitude,
              sign,
              neighbors,
              processing,
              mq,
              width,
              height,
              bpnoPlusOne,
              orientation,
              false,
            );
          case 2:
            _cleanupPass(
              magnitude,
              sign,
              neighbors,
              processing,
              mq,
              width,
              height,
              bpnoPlusOne,
              orientation,
              vsc,
              cblkStyle,
            );
        }
        if ((cblkStyle & kJpxCblkStyleReset) != 0) {
          mq.loadContextState(JpxMqDecoder.freshContextState());
        }
        if (++passtype == 3) {
          passtype = 0;
          bpnoPlusOne--;
        }
        remaining--;
      }
    }

    if (roiShift != 0) {
      if (roiShift >= 31) {
        magnitude.fillRange(0, count, 0);
      } else {
        final threshold = 1 << roiShift;
        for (var index = 0; index < count; index++) {
          final value = magnitude[index];
          final abs = value.isNegative ? -value : value;
          if (abs >= threshold) {
            final shifted = abs >> roiShift;
            magnitude[index] = value.isNegative ? -shifted : shifted;
          }
        }
      }
    }
    return magnitude;
  }

  /// Propagates significance of (row, column) to the neighbour
  /// counters; [vsc] drops the propagation across the top row of each
  /// four-row stripe.
  static void _setNeighbors(
    final Uint8List neighbors,
    final int width,
    final int height,
    final int row,
    final int column,
    final bool vsc,
  ) {
    final index = row * width + column;
    final left = column > 0;
    final right = column + 1 < width;
    if (row > 0 && !(vsc && row % 4 == 0)) {
      final north = index - width;
      if (left) neighbors[north - 1] += 0x10;
      if (right) neighbors[north + 1] += 0x10;
      neighbors[north] += 0x04;
    }
    if (row + 1 < height) {
      final south = index + width;
      if (left) neighbors[south - 1] += 0x10;
      if (right) neighbors[south + 1] += 0x10;
      neighbors[south] += 0x04;
    }
    if (left) neighbors[index - 1] += 0x01;
    if (right) neighbors[index + 1] += 0x01;
    neighbors[index] |= 0x80;
  }

  /// Decodes the sign bit of a just-significant sample (contexts 9-13
  /// built from the W/E then N/S sign contributions).
  static int _decodeSignBit(
    final Int32List magnitude,
    final Uint8List sign,
    final JpxMqDecoder mq,
    final int width,
    final int height,
    final int row,
    final int column,
    final int index,
  ) {
    int contribution;
    var significance = column > 0 && magnitude[index - 1] != 0;
    if (column + 1 < width && magnitude[index + 1] != 0) {
      final east = sign[index + 1];
      if (significance) {
        final west = sign[index - 1];
        contribution = 1 - east - west;
      } else {
        contribution = 1 - east - east;
      }
    } else if (significance) {
      final west = sign[index - 1];
      contribution = 1 - west - west;
    } else {
      contribution = 0;
    }
    final horizontal = 3 * contribution;

    significance = row > 0 && magnitude[index - width] != 0;
    if (row + 1 < height && magnitude[index + width] != 0) {
      final south = sign[index + width];
      if (significance) {
        final north = sign[index - width];
        contribution = 1 - south - north + horizontal;
      } else {
        contribution = 1 - south - south + horizontal;
      }
    } else if (significance) {
      final north = sign[index - width];
      contribution = 1 - north - north + horizontal;
    } else {
      contribution = horizontal;
    }

    if (contribution >= 0) {
      return mq.decode(_ctxSc + contribution);
    }
    return mq.decode(_ctxSc - contribution) ^ 1;
  }

  static void _significancePass(
    final Int32List magnitude,
    final Uint8List sign,
    final Uint8List neighbors,
    final Uint8List processing,
    final JpxMqDecoder mq,
    final int width,
    final int height,
    final int bpno,
    final int orientation,
    final int vsc,
    final bool raw,
  ) {
    final labels = _kLabelTables[orientation];
    final one = 1 << bpno;
    final oneAndHalf = one | (one >> 1);
    final processedInverseMask = ~1;
    final firstMagnitudeBitMask = 2;
    for (var stripe = 0; stripe < height; stripe += 4) {
      for (var column = 0; column < width; column++) {
        var index = stripe * width + column;
        for (var rowInStripe = 0; rowInStripe < 4; rowInStripe++, index += width) {
          final row = stripe + rowInStripe;
          if (row >= height) {
            break;
          }
          processing[index] &= processedInverseMask;
          if (magnitude[index] != 0 || neighbors[index] == 0) {
            continue;
          }
          final decision = raw ? mq.decodeRaw() : mq.decode(labels[neighbors[index]]);
          if (decision != 0) {
            final decodedSign = raw
                ? mq.decodeRaw()
                : _decodeSignBit(magnitude, sign, mq, width, height, row, column, index);
            sign[index] = decodedSign;
            magnitude[index] = decodedSign == 1 ? -oneAndHalf : oneAndHalf;
            _setNeighbors(neighbors, width, height, row, column, vsc != 0);
            processing[index] |= firstMagnitudeBitMask;
          }
          processing[index] |= 1;
        }
      }
    }
  }

  static void _refinementPass(
    final Int32List magnitude,
    final Uint8List sign,
    final Uint8List neighbors,
    final Uint8List processing,
    final JpxMqDecoder mq,
    final int width,
    final int height,
    final int bpno,
    final int orientation,
    final bool raw,
  ) {
    final one = 1 << bpno;
    final posHalf = one >> 1;
    // Refinement decodes in the same four-row-stripe scan order the
    // encoder wrote, so the MQ symbol sequence matches.
    for (var stripe = 0; stripe < height; stripe += 4) {
      final stripeEnd = stripe + 4 < height ? stripe + 4 : height;
      for (var column = 0; column < width; column++) {
        for (var row = stripe; row < stripeEnd; row++) {
          final index = row * width + column;
          if (magnitude[index] == 0 || (processing[index] & 1) != 0) {
            continue;
          }
          var label = 16;
          if ((processing[index] & 2) != 0) {
            processing[index] ^= 2;
            // First magnitude bit: Table 9-9 gives context 15 with
            // significant neighbours, 14 without (OpenJPEG's
            // opj_t1_getctxno_mag).
            label = (neighbors[index] & 0x7F) == 0 ? 14 : 15;
          }
          final bit = raw ? mq.decodeRaw() : mq.decode(label);
          magnitude[index] += ((bit ^ (magnitude[index] < 0 ? 1 : 0)) != 0) ? posHalf : -posHalf;
          processing[index] |= 1;
        }
      }
    }
  }

  static void _cleanupPass(
    final Int32List magnitude,
    final Uint8List sign,
    final Uint8List neighbors,
    final Uint8List processing,
    final JpxMqDecoder mq,
    final int width,
    final int height,
    final int bpno,
    final int orientation,
    final int vsc,
    final int cblkStyle,
  ) {
    final labels = _kLabelTables[orientation];
    final one = 1 << bpno;
    final oneAndHalf = one | (one >> 1);
    final firstMagnitudeBitMask = 2;
    for (var stripe = 0; stripe < height; stripe += 4) {
      final stripeEnd = stripe + 4 < height ? stripe + 4 : height;
      final checkAllEmpty = stripe + 3 < height;
      for (var column = 0; column < width; column++) {
        final baseIndex = stripe * width + column;
        final allEmpty =
            checkAllEmpty &&
            processing[baseIndex] == 0 &&
            processing[baseIndex + width] == 0 &&
            processing[baseIndex + 2 * width] == 0 &&
            processing[baseIndex + 3 * width] == 0 &&
            neighbors[baseIndex] == 0 &&
            neighbors[baseIndex + width] == 0 &&
            neighbors[baseIndex + 2 * width] == 0 &&
            neighbors[baseIndex + 3 * width] == 0;
        var runStart = stripe;
        if (allEmpty) {
          if (mq.decode(_ctxAgg) == 0) {
            continue;
          }
          final run = (mq.decode(_ctxUni) << 1) | mq.decode(_ctxUni);
          final row = stripe + run;
          final index = row * width + column;
          final decodedSign = _decodeSignBit(
            magnitude,
            sign,
            mq,
            width,
            height,
            row,
            column,
            index,
          );
          sign[index] = decodedSign;
          magnitude[index] = decodedSign == 1 ? -oneAndHalf : oneAndHalf;
          _setNeighbors(neighbors, width, height, row, column, vsc != 0);
          processing[index] |= firstMagnitudeBitMask;
          runStart = row + 1;
        }
        for (var row = runStart; row < stripeEnd; row++) {
          final index = row * width + column;
          if (magnitude[index] != 0 || (processing[index] & 1) != 0) {
            continue;
          }
          if (mq.decode(labels[neighbors[index]]) != 0) {
            final decodedSign = _decodeSignBit(
              magnitude,
              sign,
              mq,
              width,
              height,
              row,
              column,
              index,
            );
            sign[index] = decodedSign;
            magnitude[index] = decodedSign == 1 ? -oneAndHalf : oneAndHalf;
            _setNeighbors(neighbors, width, height, row, column, vsc != 0);
            processing[index] |= firstMagnitudeBitMask;
          }
        }
      }
    }
    if ((cblkStyle & kJpxCblkStyleSegmentation) != 0) {
      // OpenJPEG reads the segmentation symbol and only warns on
      // mismatch; the value never changes the decoded coefficients.
      mq.decode(_ctxUni);
      mq.decode(_ctxUni);
      mq.decode(_ctxUni);
      mq.decode(_ctxUni);
    }
  }
}
