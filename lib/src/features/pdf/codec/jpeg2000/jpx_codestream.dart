import 'dart:typed_data';

import 'jpx_exception.dart';
import 'jpx_limits.dart';

/// Codestream marker codes (ISO/IEC 15444-1 Annex A).

/// SOC: start of codestream.
const int kMarkerSoc = 0xFF4F;

/// SIZ: image and tile size.
const int kMarkerSiz = 0xFF51;

/// COD: coding style default.
const int kMarkerCod = 0xFF52;

/// COC: coding style component override.
const int kMarkerCoc = 0xFF53;

/// QCD: quantization default.
const int kMarkerQcd = 0xFF5C;

/// QCC: quantization component override.
const int kMarkerQcc = 0xFF5D;

/// RGN: region-of-interest shift (rejected by this subset).
const int kMarkerRgn = 0xFF5E;

/// POC: progression order change (rejected by this subset).
const int kMarkerPoc = 0xFF5F;

/// TLM: tile-part lengths, main header (skipped when present).
const int kMarkerTlm = 0xFF55;

/// PLM: packet length, main header (skipped when present).
const int kMarkerPlm = 0xFF57;

/// PLT: packet length, tile-part header (skipped when present).
const int kMarkerPlt = 0xFF58;

/// PPM: packed packet headers, main header (rejected by this subset).
const int kMarkerPpm = 0xFF60;

/// PPT: packed packet headers, tile-part (rejected by this subset).
const int kMarkerPpt = 0xFF61;

/// SOP: start of packet.
const int kMarkerSop = 0xFF91;

/// EPH: end of packet header.
const int kMarkerEph = 0xFF92;

/// CRG: component registration (skipped when present).
const int kMarkerCrg = 0xFF63;

/// COM: comment (skipped when present).
const int kMarkerCom = 0xFF64;

/// SOT: start of tile-part.
const int kMarkerSot = 0xFF90;

/// SOD: start of data.
const int kMarkerSod = 0xFF93;

/// EOC: end of codestream.
const int kMarkerEoc = 0xFFD9;

/// CAP: extended capability marker (rejected by this subset).
const int kMarkerCap = 0xFF50;

/// Progression orders the codec accepts.
///
/// * [kProgressionLrcp] LRCP: layer-resolution-component-position.
/// * [kProgressionRlcp] RLCP: resolution-layer-component-position.
const int kProgressionLrcp = 0;

/// RLCP: resolution-layer-component-position.
const int kProgressionRlcp = 1;

/// SPcod value 1: the reversible 5/3 integer wavelet.
const int kTransformReversible = 1;

/// SPcod value 0: the irreversible 9/7 floating-point wavelet.
const int kTransformIrreversible = 0;

/// SQcd style 0: no quantization, exponents only.
const int kQuantizationNone = 0;

/// SQcd style 1: scalar derived, one exponent/mantissa pair
/// shared by all bands.
const int kQuantizationScalarDerived = 1;

/// SQcd style 2: scalar expounded, one exponent/mantissa pair
/// per band.
const int kQuantizationScalarExpounded = 2;

/// Scod/Scoc flag: custom precinct sizes follow.
const int kSegmentStylePrecincts = 0x01;

/// Scod/Scoc flag: SOP markers may appear between packets.
const int kSegmentStyleSop = 0x02;

/// Scod/Scoc flag: EPH markers follow every packet header.
const int kSegmentStyleEph = 0x04;

/// Bounds-checked cursor over one codestream segment.
final class JpxReader {
  /// Wraps [data] between [offset] and [end]; the range must lie inside
  /// the buffer.
  JpxReader(this.data, this.offset, this.end) {
    if (offset < 0 || end < offset || end > data.length) {
      throw const JpxException('JPEG 2000 segment escapes the buffer.');
    }
    _cursor = offset;
  }

  /// The buffer the segment lives in.
  final Uint8List data;

  /// First byte of the segment.
  final int offset;

  /// One past the last byte of the segment.
  final int end;
  late int _cursor;

  /// Bytes left between the cursor and the segment end.
  int get remaining => end - _cursor;

  /// Current absolute read position.
  int get cursor => _cursor;

  /// Reads one byte, failing with a typed error at the segment end.
  int readByte() {
    if (_cursor >= end) {
      throw const JpxException('JPEG 2000 marker segment is truncated.');
    }
    return data[_cursor++];
  }

  /// Reads a big-endian 16-bit word.
  int readUint16() => (readByte() << 8) | readByte();

  /// Reads a big-endian 32-bit word.
  int readUint32() =>
      ((readByte() << 24) | (readByte() << 16) | (readByte() << 8) | readByte()) & 0xFFFFFFFF;

  /// Advances past [count] bytes without reading them.
  void skip(final int count) {
    if (count < 0 || count > remaining) {
      throw const JpxException('JPEG 2000 marker segment is truncated.');
    }
    _cursor += count;
  }

  /// Returns a fresh reader over the next [count] bytes and advances
  /// past them.
  JpxReader slice(final int count) {
    if (count < 0 || count > remaining) {
      throw const JpxException('JPEG 2000 marker segment is truncated.');
    }
    final sliced = JpxReader(data, _cursor, _cursor + count);
    _cursor += count;
    return sliced;
  }
}

/// Per-component coding parameters (the standard's `tccp`): what COD
/// establishes and COC/QCC override per component.
final class JpxComponentCoding {
  /// Scod/Scoc: precinct-defined and SOP/EPH flags.
  int segmentStyle = 0;

  /// SPcod code-block style (bypass, reset, terminate, VSC, segmark).
  int codeblockStyle = 0;

  /// SGcod progression order (LRCP or RLCP in this subset).
  int progressionOrder = kProgressionLrcp;

  /// SGcod quality layer count.
  int layerCount = 1;

  /// SPcod MCT flag: 1 when RCT/ICT is applied across components.
  int multiComponentTransform = 0;

  /// SPcod decomposition level count (resolutions are levels + 1).
  int decompositionLevels = 0;

  /// SPcod code-block width exponent (real width is 2^exponent).
  int codeblockWidthExp = 4;

  /// SPcod code-block height exponent (real height is 2^exponent).
  int codeblockHeightExp = 4;

  /// SPcod wavelet: [kTransformReversible] or
  /// [kTransformIrreversible].
  int transform = kTransformReversible;

  /// SPqcd guard bits protecting against coefficient overflow.
  int guardBits = 2;

  /// SQcd style: none, scalar derived, or scalar expounded.
  int quantizationStyle = kQuantizationNone;

  /// Scod/Scoc packed precinct sizes, resolution 0 upward.
  final List<int> precinctPacked = <int>[];

  /// Per-band quantization exponents in band order.
  final List<int> stepExponents = <int>[];

  /// Per-band quantization mantissas matching [stepExponents].
  final List<int> stepMantissas = <int>[];

  /// Code-block width in samples.
  int get codeblockWidth => 1 << codeblockWidthExp;

  /// Code-block height in samples.
  int get codeblockHeight => 1 << codeblockHeightExp;

  /// Whether Scod/Scoc declares custom precinct sizes.
  bool get hasCustomPrecincts => (segmentStyle & kSegmentStylePrecincts) != 0;

  /// Whether SOP markers may appear between packets.
  bool get usesSop => (segmentStyle & kSegmentStyleSop) != 0;

  /// Whether EPH markers follow every packet header.
  bool get usesEph => (segmentStyle & kSegmentStyleEph) != 0;

  /// Copies the shared COD/QCD defaults into this component.
  void setFrom(final JpxComponentCoding other) {
    segmentStyle = other.segmentStyle;
    codeblockStyle = other.codeblockStyle;
    progressionOrder = other.progressionOrder;
    layerCount = other.layerCount;
    multiComponentTransform = other.multiComponentTransform;
    decompositionLevels = other.decompositionLevels;
    codeblockWidthExp = other.codeblockWidthExp;
    codeblockHeightExp = other.codeblockHeightExp;
    transform = other.transform;
    guardBits = other.guardBits;
    quantizationStyle = other.quantizationStyle;
    roiShift = other.roiShift;
    precinctPacked
      ..clear()
      ..addAll(other.precinctPacked);
    stepExponents
      ..clear()
      ..addAll(other.stepExponents);
    stepMantissas
      ..clear()
      ..addAll(other.stepMantissas);
  }

  /// ROI up-shift is parsed for validation but not supported yet.
  int roiShift = 0;
}

/// Parsed SIZ marker.
final class JpxImageInfo {
  /// Left edge of the image grid (Xsiz).
  int x0 = 0;

  /// Top edge of the image grid (Ysiz).
  int y0 = 0;

  /// Image width in samples (Xsiz - XOsiz).
  int width = 0;

  /// Image height in samples (Ysiz - YOsiz).
  int height = 0;

  /// Left edge of the first tile grid point (XTOsiz).
  int tileX0 = 0;

  /// Top edge of the first tile grid point (YTOsiz).
  int tileY0 = 0;

  /// Tile width in samples (XTsiz).
  int tileWidth = 0;

  /// Tile height in samples (YTsiz).
  int tileHeight = 0;

  /// Component count (Csiz).
  int componentCount = 0;

  /// Tiles per row of the tile grid.
  int get tileCountX =>
      width <= tileX0 || tileWidth <= 0 ? 0 : ((width - tileX0) + tileWidth - 1) ~/ tileWidth;

  /// Tiles per column of the tile grid.
  int get tileCountY =>
      height <= tileY0 || tileHeight <= 0 ? 0 : ((height - tileY0) + tileHeight - 1) ~/ tileHeight;
}

/// One tile-part of one tile: the byte range after SOD that carries
/// packets.
final class JpxTilePart {
  /// Index of the owning tile, tile-parts follow in order.
  JpxTilePart(this.tileIndex, this.partIndex, this.partCount, this.dataStart, this.dataLength);

  /// The tile this part belongs to.
  final int tileIndex;

  /// Zero-based position of this part within the tile.
  final int partIndex;

  /// Total tile-parts declared for the tile (Psot scan).
  final int partCount;

  /// Absolute offset of the packet data (after SOD).
  final int dataStart;

  /// Packet data byte count of this part.
  int dataLength;
}

/// The result of the marker scan: image geometry, per-component coding
/// and the tile-part layout.
final class JpxCodestreamInfo {
  /// Parsed SIZ geometry.
  final JpxImageInfo image = JpxImageInfo();

  /// One entry per component, COD defaults with COC/QCC applied.
  final List<JpxComponentCoding> componentCoding = <JpxComponentCoding>[];

  /// Tile-parts in codestream order.
  final List<JpxTilePart> tileParts = <JpxTilePart>[];
}

void _parseSiz(final JpxReader reader, final JpxCodestreamInfo info) {
  final image = info.image;
  final capability = reader.readUint16();
  if (capability & 0x3FFF != 0) {
    throw const JpxUnsupportedException('JPEG 2000 Part 2 capability bits are not supported.');
  }
  image.width = reader.readUint32();
  image.height = reader.readUint32();
  image.x0 = reader.readUint32();
  image.y0 = reader.readUint32();
  image.tileWidth = reader.readUint32();
  image.tileHeight = reader.readUint32();
  image.tileX0 = reader.readUint32();
  image.tileY0 = reader.readUint32();
  image.componentCount = reader.readUint16();
  if (image.componentCount < 1 || image.componentCount > kJpxMaxComponents) {
    throw const JpxException('JPEG 2000 component count is out of range.');
  }
  if (image.width <= image.x0 || image.height <= image.y0) {
    throw const JpxException('JPEG 2000 image extent is empty.');
  }
  if (image.tileWidth <= 0 || image.tileHeight <= 0) {
    throw const JpxException('JPEG 2000 tile size is invalid.');
  }
  if (image.tileX0 > image.x0 || image.tileY0 > image.y0) {
    throw const JpxException('JPEG 2000 tile grid origin is invalid.');
  }
  final tiles = image.tileCountX * image.tileCountY;
  if (tiles <= 0 || tiles > kJpxMaxTiles) {
    throw const JpxException('JPEG 2000 tile count exceeds the codec budget.');
  }
  for (final coordinate in <int>[
    image.x0,
    image.y0,
    image.width,
    image.height,
    image.tileX0,
    image.tileY0,
    image.tileWidth,
    image.tileHeight,
  ]) {
    if (coordinate > kJpxMaxCoordinate) {
      throw const JpxException('JPEG 2000 coordinates exceed 31 bits.');
    }
  }
  for (var component = 0; component < image.componentCount; component++) {
    final precisionByte = reader.readByte();
    if ((precisionByte & 0x7F) + 1 != 8 || precisionByte & 0x80 != 0) {
      throw const JpxUnsupportedException(
        'JPEG 2000 components must be unsigned 8-bit in this subset.',
      );
    }
    if (reader.readByte() != 1 || reader.readByte() != 1) {
      throw const JpxUnsupportedException('JPEG 2000 component subsampling is not supported.');
    }
  }
}

void _validateCoding(final JpxComponentCoding coding) {
  if (coding.progressionOrder != kProgressionLrcp && coding.progressionOrder != kProgressionRlcp) {
    throw const JpxUnsupportedException('Only LRCP and RLCP progression orders are supported.');
  }
  if (coding.multiComponentTransform > 1) {
    throw const JpxUnsupportedException('Custom multiple component transforms are not supported.');
  }
  if (coding.layerCount < 1 || coding.layerCount > kJpxMaxLayers) {
    throw const JpxException('JPEG 2000 quality layer count is out of range.');
  }
  if (coding.decompositionLevels > kJpxMaxDecompositionLevels) {
    throw const JpxException('JPEG 2000 decomposition level count is out of range.');
  }
  if (coding.codeblockWidthExp < 2 ||
      coding.codeblockWidthExp > 10 ||
      coding.codeblockHeightExp < 2 ||
      coding.codeblockHeightExp > 10 ||
      coding.codeblockWidthExp + coding.codeblockHeightExp > 12) {
    throw const JpxException('JPEG 2000 code-block size is invalid.');
  }
  if (coding.codeblockStyle & kJpxCblkStyleBypass != 0) {
    throw const JpxUnsupportedException('JPEG 2000 arithmetic coding bypass is not supported.');
  }
  if (coding.transform != kTransformReversible && coding.transform != kTransformIrreversible) {
    throw const JpxException('JPEG 2000 transform selection is invalid.');
  }
  if (coding.transform == kTransformIrreversible &&
      coding.quantizationStyle == kQuantizationNone &&
      coding.stepExponents.isNotEmpty) {
    // Checked after QCD lands; validated in the tile decoder instead.
  }
  if (coding.roiShift != 0) {
    throw const JpxUnsupportedException('JPEG 2000 ROI up-shift is not supported.');
  }
}

/// Parses the SPcoc body of a COC (already past Lcoc and Ccoc).
void _parseCocBody(final JpxReader body, final JpxComponentCoding coding) {
  coding.segmentStyle = body.readByte();
  coding.progressionOrder = body.readByte();
  coding.layerCount = body.readUint16();
  coding.multiComponentTransform = body.readByte();
  coding.decompositionLevels = body.readByte();
  coding.codeblockWidthExp = body.readByte() + 2;
  coding.codeblockHeightExp = body.readByte() + 2;
  coding.codeblockStyle = body.readByte();
  coding.transform = body.readByte();
  _validateCoding(coding);
  coding.precinctPacked.clear();
  if (coding.hasCustomPrecincts) {
    for (var level = 0; level <= coding.decompositionLevels; level++) {
      coding.precinctPacked.add(body.readByte());
    }
  }
}

/// Parses the body of a QCC (already past Lqcc and Cqcc).
void _parseQccBody(final JpxReader body, final JpxComponentCoding coding) {
  final styleByte = body.readByte();
  coding.guardBits = (styleByte >> 5) & 0x03;
  coding.quantizationStyle = styleByte & 0x1F;
  final bands = coding.decompositionLevels == 0 ? 1 : coding.decompositionLevels * 3 + 1;
  coding.stepExponents.clear();
  coding.stepMantissas.clear();
  switch (coding.quantizationStyle) {
    case kQuantizationNone:
      for (var band = 0; band < bands; band++) {
        coding.stepExponents.add(body.readByte() >> 3);
        coding.stepMantissas.add(0);
      }
    case kQuantizationScalarDerived:
      final high = body.readByte();
      final low = body.readByte();
      final exponent = high >> 3;
      final mantissa = ((high & 0x07) << 8) | low;
      for (var band = 0; band < bands; band++) {
        coding.stepExponents.add(exponent);
        coding.stepMantissas.add(mantissa);
      }
    case kQuantizationScalarExpounded:
      for (var band = 0; band < bands; band++) {
        final high = body.readByte();
        final low = body.readByte();
        coding.stepExponents.add(high >> 3);
        coding.stepMantissas.add(((high & 0x07) << 8) | low);
      }
    default:
      throw const JpxException('JPEG 2000 quantization style is invalid.');
  }
}

/// Walks the marker segments of a raw J2K codestream and collects the
/// geometry, coding parameters and tile-part layout.
JpxCodestreamInfo parseCodestream(final Uint8List bytes) {
  if (bytes.length < 4 ||
      (bytes[0] << 8 | bytes[1]) != kMarkerSoc ||
      (bytes[2] << 8 | bytes[3]) != kMarkerSiz) {
    throw const JpxException('Not a JPEG 2000 codestream (missing SOC/SIZ).');
  }
  final info = JpxCodestreamInfo();
  final reader = JpxReader(bytes, 2, bytes.length);
  var seenCod = false;
  var seenQcd = false;
  var inTileParts = false;

  while (reader.remaining >= 2) {
    final marker = reader.readUint16();
    switch (marker) {
      case kMarkerSiz:
        if (inTileParts || info.componentCoding.isNotEmpty) {
          throw const JpxException('SIZ appears twice in the codestream.');
        }
        final body = reader.slice(reader.readUint16() - 2);
        _parseSiz(body, info);
        for (var i = 0; i < info.image.componentCount; i++) {
          info.componentCoding.add(JpxComponentCoding());
        }
      case kMarkerCod:
        if (info.componentCoding.isEmpty) {
          throw const JpxException('COD precedes SIZ.');
        }
        final body = reader.slice(reader.readUint16() - 2);
        final shared = JpxComponentCoding();
        shared.segmentStyle = body.readByte();
        shared.progressionOrder = body.readByte();
        shared.layerCount = body.readUint16();
        shared.multiComponentTransform = body.readByte();
        shared.decompositionLevels = body.readByte();
        shared.codeblockWidthExp = body.readByte() + 2;
        shared.codeblockHeightExp = body.readByte() + 2;
        shared.codeblockStyle = body.readByte();
        shared.transform = body.readByte();
        _validateCoding(shared);
        shared.precinctPacked.clear();
        if (shared.hasCustomPrecincts) {
          for (var level = 0; level <= shared.decompositionLevels; level++) {
            shared.precinctPacked.add(body.readByte());
          }
        }
        for (final coding in info.componentCoding) {
          coding.setFrom(shared);
        }
        seenCod = true;
      case kMarkerCoc:
        if (!seenCod) {
          throw const JpxException('COC precedes COD.');
        }
        final body = reader.slice(reader.readUint16() - 2);
        final component = info.image.componentCount > 256 ? body.readUint16() : body.readByte();
        if (component < 0 || component >= info.image.componentCount) {
          throw const JpxException('COC names a component outside the image.');
        }
        _parseCocBody(body, info.componentCoding[component]);
      case kMarkerQcd:
        if (info.componentCoding.isEmpty) {
          throw const JpxException('QCD precedes SIZ.');
        }
        final bodyLength = reader.readUint16() - 2;
        final bodyOffset = reader.cursor;
        for (final coding in info.componentCoding) {
          // Each component may carry a different decomposition-level
          // count, so the shared QCD body is re-read per component to
          // validate its declared band count.
          final body = JpxReader(reader.data, bodyOffset, bodyOffset + bodyLength);
          final styleByte = body.readByte();
          coding.guardBits = (styleByte >> 5) & 0x03;
          coding.quantizationStyle = styleByte & 0x1F;
          final bands = coding.decompositionLevels == 0 ? 1 : coding.decompositionLevels * 3 + 1;
          coding.stepExponents.clear();
          coding.stepMantissas.clear();
          switch (coding.quantizationStyle) {
            case kQuantizationNone:
              for (var band = 0; band < bands; band++) {
                coding.stepExponents.add(body.readByte() >> 3);
                coding.stepMantissas.add(0);
              }
            case kQuantizationScalarDerived:
              final high = body.readByte();
              final low = body.readByte();
              final exponent = high >> 3;
              final mantissa = ((high & 0x07) << 8) | low;
              for (var band = 0; band < bands; band++) {
                coding.stepExponents.add(exponent);
                coding.stepMantissas.add(mantissa);
              }
            case kQuantizationScalarExpounded:
              for (var band = 0; band < bands; band++) {
                final high = body.readByte();
                final low = body.readByte();
                coding.stepExponents.add(high >> 3);
                coding.stepMantissas.add(((high & 0x07) << 8) | low);
              }
            default:
              throw const JpxException('JPEG 2000 quantization style is invalid.');
          }
        }
        reader.skip(bodyLength);
        seenQcd = true;
      case kMarkerQcc:
        if (!seenQcd) {
          throw const JpxException('QCC precedes QCD.');
        }
        final body = reader.slice(reader.readUint16() - 2);
        final component = info.image.componentCount > 256 ? body.readUint16() : body.readByte();
        if (component < 0 || component >= info.image.componentCount) {
          throw const JpxException('QCC names a component outside the image.');
        }
        _parseQccBody(body, info.componentCoding[component]);
      case kMarkerRgn:
        throw const JpxUnsupportedException('JPEG 2000 ROI (RGn) markers are not supported.');
      case kMarkerPoc:
        throw const JpxUnsupportedException(
          'JPEG 2000 progression order changes are not supported.',
        );
      case kMarkerPpm:
      case kMarkerPpt:
        throw const JpxUnsupportedException('JPEG 2000 packed packet headers are not supported.');
      case kMarkerCap:
        throw const JpxUnsupportedException('JPEG 2000 Part 2 extensions (CAP) are not supported.');
      case kMarkerTlm:
      case kMarkerPlm:
      case kMarkerPlt:
      case kMarkerCrg:
      case kMarkerCom:
        reader.skip(reader.readUint16() - 2);
      case kMarkerSot:
        inTileParts = true;
        if (reader.readUint16() != 10) {
          throw const JpxException('JPEG 2000 SOT segment has an invalid length.');
        }
        final body = reader.slice(8);
        final tileIndex = body.readUint16();
        final partLength = body.readUint32();
        final partIndex = body.readByte();
        final partCount = body.readByte();
        final tileTotal = info.image.tileCountX * info.image.tileCountY;
        if (tileIndex >= tileTotal) {
          throw const JpxException('SOT names a tile outside the image.');
        }
        if (partCount == 0 || partIndex >= partCount) {
          throw const JpxException('JPEG 2000 tile-part numbering is invalid.');
        }
        if (partCount > kJpxMaxTileParts) {
          throw const JpxException('JPEG 2000 tile-part count is out of range.');
        }
        if (reader.readUint16() != kMarkerSod) {
          throw const JpxException('Tile-part does not start with SOD.');
        }
        var dataLength = reader.remaining;
        if (partLength != 0) {
          // Psot spans from the first SOT byte through the tile-part
          // data (SOT header + SOD + payload), ending at the next
          // marker — EOC for the last tile-part.
          if (partLength < 14) {
            throw const JpxException('JPEG 2000 tile-part length is too small.');
          }
          dataLength = partLength - 14;
          if (dataLength > reader.remaining) {
            throw const JpxException('JPEG 2000 tile-part length exceeds the codestream.');
          }
        }
        info.tileParts.add(JpxTilePart(tileIndex, partIndex, partCount, reader.cursor, dataLength));
        reader.skip(dataLength);
      case kMarkerEoc:
        if (!inTileParts) {
          throw const JpxException('EOC without tile-parts.');
        }
        return info;
      default:
        if (marker >= 0xFF30 && marker <= 0xFF3F) {
          reader.skip(reader.readUint16() - 2);
          continue;
        }
        throw JpxException('Unexpected JPEG 2000 marker 0x${marker.toRadixString(16)}.');
    }
  }
  throw const JpxException('JPEG 2000 codestream ends without EOC.');
}

/// Result of opening a JPEG 2000 payload: either a bare codestream or
/// the codestream extracted from a JP2 wrapper plus the wrapper's
/// declared color space.
final class JpxPayload {
  /// Wraps the extracted codestream and the wrapper metadata when the
  /// payload came from a JP2.
  JpxPayload({
    required this.codestream,
    required this.isJp2,
    this.enumcs,
    this.wrapperWidth,
    this.wrapperHeight,
    this.wrapperComponents,
  });

  /// The J2K codestream bytes (wrapper stripped).
  final Uint8List codestream;

  /// Whether [codestream] was extracted from a JP2 wrapper.
  final bool isJp2;

  /// JP2 `colr` enumerated colorspace: 16 sYCC, 17 sRGB, 18 gray.
  /// Null for bare codestreams and non-enumerated methods.
  final int? enumcs;

  /// JP2 `ihdr` declarations, cross-checked against the codestream.
  final int? wrapperWidth;

  /// JP2 `ihdr` height in samples.
  final int? wrapperHeight;

  /// JP2 `ihdr` component count.
  final int? wrapperComponents;
}

/// Detects a JP2 wrapper and extracts the first contiguous codestream,
/// or passes a bare J2K payload through.
JpxPayload openJpxPayload(final Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x00 &&
      bytes[1] == 0x00 &&
      bytes[2] == 0x00 &&
      bytes[3] == 0x0C &&
      bytes[4] == 0x6A &&
      bytes[5] == 0x50 &&
      bytes[6] == 0x20 &&
      bytes[7] == 0x20) {
    return _openJp2(bytes);
  }
  return JpxPayload(codestream: bytes, isJp2: false);
}

JpxPayload _openJp2(final Uint8List bytes) {
  var cursor = 0;
  int? enumcs;
  int? wrapperWidth;
  int? wrapperHeight;
  int? wrapperComponents;
  Uint8List? codestream;
  var seenSignature = false;
  var seenHeader = false;
  while (cursor + 8 <= bytes.length) {
    final length =
        ((bytes[cursor] << 24) |
            (bytes[cursor + 1] << 16) |
            (bytes[cursor + 2] << 8) |
            bytes[cursor + 3]) &
        0xFFFFFFFF;
    final type = String.fromCharCodes(bytes.sublist(cursor + 4, cursor + 8));
    var bodyStart = cursor + 8;
    var boxEnd = cursor + length;
    if (length == 0) {
      boxEnd = bytes.length;
    } else if (length == 1) {
      // 64-bit extended length: the high word must be empty for files
      // that fit memory.
      if (cursor + 16 > bytes.length) {
        throw const JpxException('JP2 box header is truncated.');
      }
      final high =
          ((bytes[cursor + 8] << 24) |
              (bytes[cursor + 9] << 16) |
              (bytes[cursor + 10] << 8) |
              bytes[cursor + 11]) &
          0xFFFFFFFF;
      if (high != 0) {
        throw const JpxException('JP2 box is too large to decode.');
      }
      bodyStart = cursor + 16;
      boxEnd =
          ((bytes[cursor + 12] << 24) |
              (bytes[cursor + 13] << 16) |
              (bytes[cursor + 14] << 8) |
              bytes[cursor + 15]) &
          0xFFFFFFFF + cursor;
    }
    if (boxEnd < bodyStart || boxEnd > bytes.length) {
      throw const JpxException('JP2 box length is invalid.');
    }
    switch (type) {
      case 'jP  ':
        seenSignature = true;
      case 'ftyp':
        break;
      case 'jp2h':
        _readJp2HeaderBox(bytes, bodyStart, boxEnd, (
          final meth,
          final value, {
          final int? width,
          final int? height,
          final int? components,
        }) {
          if (width != null) {
            wrapperWidth = width;
            wrapperHeight = height;
            wrapperComponents = components;
            return;
          }
          if (meth == 1) {
            enumcs = value;
          } else if (meth == 2) {
            throw const JpxUnsupportedException('JP2 embedded ICC profiles are not supported.');
          } else {
            throw const JpxUnsupportedException('JP2 palette color spaces are not supported.');
          }
        });
        seenHeader = true;
      case 'jp2c':
        codestream ??= Uint8List.sublistView(bytes, bodyStart, boxEnd);
      case 'jpch':
      case 'jplh':
        throw const JpxUnsupportedException('JP2 multiple-frames boxes are not supported.');
      default:
        break; // dtbl, rreq, unknown, and UUID boxes are skipped.
    }
    if (length == 0) {
      break;
    }
    cursor = boxEnd;
  }
  if (!seenSignature) {
    throw const JpxException('JP2 wrapper lacks the signature box.');
  }
  if (!seenHeader) {
    throw const JpxException('JP2 wrapper lacks the header box.');
  }
  if (codestream == null) {
    throw const JpxException('JP2 wrapper lacks a codestream box.');
  }
  return JpxPayload(
    codestream: codestream,
    isJp2: true,
    enumcs: enumcs,
    wrapperWidth: wrapperWidth,
    wrapperHeight: wrapperHeight,
    wrapperComponents: wrapperComponents,
  );
}

/// Walks the `jp2h` superbox; [onBox] receives the `ihdr` geometry
/// (with non-null dimensions) or the `colr` method and enumerated
/// value.
void _readJp2HeaderBox(
  final Uint8List bytes,
  final int start,
  final int end,
  final void Function(int method, int enumcs, {int? width, int? height, int? components}) onBox,
) {
  var cursor = start;
  var seenIhdr = false;
  while (cursor + 8 <= end) {
    final length =
        ((bytes[cursor] << 24) |
            (bytes[cursor + 1] << 16) |
            (bytes[cursor + 2] << 8) |
            bytes[cursor + 3]) &
        0xFFFFFFFF;
    final type = String.fromCharCodes(bytes.sublist(cursor + 4, cursor + 8));
    final bodyStart = cursor + 8;
    final bodyEnd = length == 0 ? end : cursor + length;
    if (bodyEnd < bodyStart || bodyEnd > end) {
      throw const JpxException('JP2 header box length is invalid.');
    }
    if (type == 'ihdr') {
      if (bodyEnd - bodyStart < 14) {
        throw const JpxException('JP2 image header box is truncated.');
      }
      final height =
          ((bytes[bodyStart] << 24) |
              (bytes[bodyStart + 1] << 16) |
              (bytes[bodyStart + 2] << 8) |
              bytes[bodyStart + 3]) &
          0xFFFFFFFF;
      final width =
          ((bytes[bodyStart + 4] << 24) |
              (bytes[bodyStart + 5] << 16) |
              (bytes[bodyStart + 6] << 8) |
              bytes[bodyStart + 7]) &
          0xFFFFFFFF;
      final componentCount = (bytes[bodyStart + 8] << 8) | bytes[bodyStart + 9];
      final bitsPerComponent = bytes[bodyStart + 10];
      final compressionType = bytes[bodyStart + 11];
      if (compressionType != 7) {
        throw const JpxUnsupportedException('JP2 wrap compression type is not JPEG 2000.');
      }
      if ((bitsPerComponent & 0x7F) + 1 != 8 || bitsPerComponent & 0x80 != 0) {
        throw const JpxUnsupportedException(
          'JP2 image header precision is outside the 8-bit unsigned subset.',
        );
      }
      if (width == 0 || height == 0 || componentCount == 0) {
        throw const JpxException('JP2 image header declares an empty image.');
      }
      onBox(0, 0, width: width, height: height, components: componentCount);
      seenIhdr = true;
    } else if (type == 'colr') {
      if (bodyEnd - bodyStart < 3) {
        throw const JpxException('JP2 color specification box is truncated.');
      }
      final method = bytes[bodyStart];
      var value = -1;
      if (method == 1) {
        if (bodyEnd - bodyStart < 7) {
          throw const JpxException('JP2 color specification box is truncated.');
        }
        value =
            ((bytes[bodyStart + 3] << 24) |
                (bytes[bodyStart + 4] << 16) |
                (bytes[bodyStart + 5] << 8) |
                bytes[bodyStart + 6]) &
            0xFFFFFFFF;
      }
      onBox(method, value);
    } else if (type == 'cdef') {
      throw const JpxUnsupportedException(
        'JP2 component definitions (alpha channels) are not supported.',
      );
    }
    cursor = bodyEnd;
  }
  if (!seenIhdr) {
    throw const JpxException('JP2 header box lacks the image header.');
  }
}
