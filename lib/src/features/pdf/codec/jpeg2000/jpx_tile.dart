import 'dart:typed_data';

import 'jpx_bitreader.dart';
import 'jpx_codestream.dart';
import 'jpx_dwt.dart';
import 'jpx_exception.dart';
import 'jpx_limits.dart';
import 'jpx_mct.dart';
import 'jpx_tagtree.dart';
import 'jpx_tier1.dart';

/// Tier-2 state of one code-block.
final class _Codeblock {
  int x0 = 0;
  int y0 = 0;
  int x1 = 0;
  int y1 = 0;
  int numbps = 0;
  int numlenBits = 3;
  final List<_Segment> segments = <_Segment>[];
  int open = -1;
  bool seen = false;
}

/// One tier-1 segment being accumulated across packets. The `chunks`
/// list keeps one (start, length) range per packet contribution —
/// multi-layer codestreams make them non-contiguous.
final class _Segment {
  int length = 0;
  int passes = 0;
  int maxPasses = 109;
  final List<(int, int)> chunks = <(int, int)>[];
}

final class _Precinct {
  _Precinct(this.x0, this.y0, this.x1, this.y1, this.cw, this.ch)
    : inclusion = JpxTagTree(cw, ch),
      imsb = JpxTagTree(cw, ch),
      cblks = List<_Codeblock>.generate(cw * ch, (final _) => _Codeblock());

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final int cw;
  final int ch;
  final JpxTagTree inclusion;
  final JpxTagTree imsb;
  final List<_Codeblock> cblks;
}

final class _Band {
  _Band(this.x0, this.y0, this.x1, this.y1, this.orientation, this.stepExponent, this.stepMantissa);

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final int orientation;
  final int stepExponent;
  final int stepMantissa;

  /// Magnitude bit-planes: Mb = G + eb - 1.
  int numbps = 0;

  /// Quantization step size (irreversible only).
  double stepSize = 1;

  final List<_Precinct> precincts = <_Precinct>[];

  bool get isEmpty => x0 >= x1 || y0 >= y1;
}

final class _Resolution {
  _Resolution(this.x0, this.y0, this.x1, this.y1);

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  int pw = 0;
  int ph = 0;
  final List<_Band> bands = <_Band>[];
}

final class _TileComponent {
  _TileComponent(this.x0, this.y0, this.x1, this.y1);

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final List<_Resolution> resolutions = <_Resolution>[];
}

/// One body write scheduled while reading a packet header, resolved
/// once the packet body position is known.
final class _PendingBody {
  _PendingBody(this.segment, this.relativeStart, this.length, this.passes);

  final _Segment segment;
  final int relativeStart;
  final int length;
  final int passes;
}

/// Decodes one tile into per-component 8-bit sample buffers covering
/// the tile's clipped region of the image.
final class JpxTileDecoder {
  /// Binds the decoder to one tile of [codestream] whose marker scan
  /// produced [info]; [imagePrecision] drives dequantization scaling.
  JpxTileDecoder({
    required this.info,
    required this.codestream,
    required this.tileIndex,
    required this.imagePrecision,
  });

  /// The marker scan result this tile belongs to.
  final JpxCodestreamInfo info;

  /// The raw J2K codestream bytes.
  final Uint8List codestream;

  /// Zero-based tile index within the tile grid.
  final int tileIndex;

  /// Declared bit depth used by dequantization and level shift.
  final int imagePrecision;

  late int _tileX0;
  late int _tileY0;
  late int _tileX1;
  late int _tileY1;
  late int _tileWidth;
  late int _componentCount;
  final List<_TileComponent> _components = <_TileComponent>[];

  late Uint8List _data;
  int _cursor = 0;

  /// Decodes the tile; returns one clipped sample buffer per component
  /// (row-major, tile-local coordinates).
  List<Uint8List> decode() {
    _computeGeometry();
    _assembleTileData();
    _runPackets();
    return _decodeTile();
  }

  int _ceilDivPow2(final int value, final int power) => (value + (1 << power) - 1) >> power;

  int _floorDivPow2(final int value, final int power) => value >> power;

  void _computeGeometry() {
    final image = info.image;
    final tilesX = image.tileCountX;
    final column = tileIndex % tilesX;
    final row = tileIndex ~/ tilesX;
    _tileX0 = image.tileX0 + column * image.tileWidth;
    _tileY0 = image.tileY0 + row * image.tileHeight;
    _tileX1 = (image.tileX0 + (column + 1) * image.tileWidth).clamp(image.x0, image.width);
    _tileY1 = (image.tileY0 + (row + 1) * image.tileHeight).clamp(image.y0, image.height);
    if (_tileX1 <= _tileX0 || _tileY1 <= _tileY0) {
      throw const JpxException('JPEG 2000 tile is empty.');
    }
    _tileWidth = _tileX1 - _tileX0;
    _componentCount = image.componentCount;

    var totalBufferSamples = 0;
    for (var component = 0; component < _componentCount; component++) {
      final coding = info.componentCoding[component];
      final tileComponent = _TileComponent(_tileX0, _tileY0, _tileX1, _tileY1);
      final numres = coding.decompositionLevels + 1;
      for (var resno = 0; resno < numres; resno++) {
        final levelNo = numres - 1 - resno;
        final resolution = _Resolution(
          _ceilDivPow2(tileComponent.x0, levelNo),
          _ceilDivPow2(tileComponent.y0, levelNo),
          _ceilDivPow2(tileComponent.x1, levelNo),
          _ceilDivPow2(tileComponent.y1, levelNo),
        );
        // The marker lists precinct sizes from resolution 0 (lowest)
        // upward; when fewer records than resolutions are supplied, the
        // last record's size halves per remaining level.
        var packed = 0xFF;
        if (coding.hasCustomPrecincts) {
          final records = coding.precinctPacked;
          if (resno < records.length) {
            packed = records[resno];
          } else {
            final shift = resno - records.length + 1;
            final last = records[records.length - 1];
            final ppx = (last >> 4) - shift;
            final ppy = (last & 0x0F) - shift;
            packed = ((ppy < 0 ? 0 : ppy) << 4) | (ppx < 0 ? 0 : ppx);
          }
        }
        final pdx = packed & 0x0F;
        final pdy = (packed >> 4) & 0x0F;
        if (resno > 0 && (pdx < 1 || pdy < 1)) {
          throw const JpxException('JPEG 2000 precinct exponent is too small for a sub-band.');
        }
        final prcX0 = _floorDivPow2(resolution.x0, pdx) << pdx;
        final prcY0 = _floorDivPow2(resolution.y0, pdy) << pdy;
        final prcX1 = _ceilDivPow2(resolution.x1, pdx) << pdx;
        final prcY1 = _ceilDivPow2(resolution.y1, pdy) << pdy;
        resolution.pw = resolution.x0 == resolution.x1 ? 0 : (prcX1 - prcX0) >> pdx;
        resolution.ph = resolution.y0 == resolution.y1 ? 0 : (prcY1 - prcY0) >> pdy;

        final bandCount = resno == 0 ? 1 : 3;
        var stepIndex = resno == 0 ? 0 : 1 + (resno - 1) * 3;
        for (var bandno = 0; bandno < bandCount; bandno++, stepIndex++) {
          final orientation = resno == 0 ? 0 : bandno + 1;
          final _Band band;
          if (resno == 0) {
            band = _Band(
              resolution.x0,
              resolution.y0,
              resolution.x1,
              resolution.y1,
              0,
              _stepExponent(coding, stepIndex),
              _stepMantissa(coding, stepIndex),
            );
          } else {
            final x0b = orientation & 1;
            final y0b = orientation >> 1;
            band = _Band(
              _ceilDivPow2(tileComponent.x0 - (x0b << levelNo), levelNo + 1),
              _ceilDivPow2(tileComponent.y0 - (y0b << levelNo), levelNo + 1),
              _ceilDivPow2(tileComponent.x1 - (x0b << levelNo), levelNo + 1),
              _ceilDivPow2(tileComponent.y1 - (y0b << levelNo), levelNo + 1),
              orientation,
              _stepExponent(coding, stepIndex),
              _stepMantissa(coding, stepIndex),
            );
          }
          band.numbps = band.stepExponent + coding.guardBits - 1;
          if (band.numbps < 0) {
            // A degenerate quantization can declare fewer bit-planes
            // than the guard adjustment; OpenJPEG then decodes none.
            band.numbps = 0;
          }
          if (band.numbps > 254) {
            throw const JpxException('JPEG 2000 band bit-plane count is out of range.');
          }
          if (coding.transform == kTransformIrreversible) {
            band.stepSize =
                (1.0 + band.stepMantissa / 2048.0) * _pow2(imagePrecision - band.stepExponent);
          }
          if (!band.isEmpty) {
            _buildPrecincts(band, resolution, coding, pdx, pdy, resno);
          }
          resolution.bands.add(band);
        }
        tileComponent.resolutions.add(resolution);
      }
      final last = tileComponent.resolutions.last;
      totalBufferSamples += budgeted(checkedProduct(last.x1 - last.x0, last.y1 - last.y0));
      _components.add(tileComponent);
    }
    if (totalBufferSamples * 4 > kJpxMaxTileBufferBytes) {
      throw JpxException(kJpxBudgetMessage);
    }
  }

  int _stepExponent(final JpxComponentCoding coding, final int index) {
    if (index >= coding.stepExponents.length) {
      throw const JpxException('JPEG 2000 quantization table is shorter than the band list.');
    }
    return coding.stepExponents[index];
  }

  int _stepMantissa(final JpxComponentCoding coding, final int index) {
    if (index >= coding.stepMantissas.length) {
      throw const JpxException('JPEG 2000 quantization table is shorter than the band list.');
    }
    return coding.stepMantissas[index];
  }

  double _pow2(final int exponent) {
    if (exponent >= 0) {
      return (1 << exponent).toDouble();
    }
    return 1.0 / (1 << -exponent).toDouble();
  }

  void _buildPrecincts(
    final _Band band,
    final _Resolution resolution,
    final JpxComponentCoding coding,
    final int pdx,
    final int pdy,
    final int resno,
  ) {
    final cbgWidthExpn = resno == 0 ? pdx : pdx - 1;
    final cbgHeightExpn = resno == 0 ? pdy : pdy - 1;
    final prcBaseX = _floorDivPow2(resolution.x0, pdx) << pdx;
    final prcBaseY = _floorDivPow2(resolution.y0, pdy) << pdy;
    final cbgBaseX = resno == 0 ? prcBaseX : _ceilDivPow2(prcBaseX, 1);
    final cbgBaseY = resno == 0 ? prcBaseY : _ceilDivPow2(prcBaseY, 1);
    final cblkWidthExpn = coding.codeblockWidthExp < cbgWidthExpn
        ? coding.codeblockWidthExp
        : cbgWidthExpn;
    final cblkHeightExpn = coding.codeblockHeightExp < cbgHeightExpn
        ? coding.codeblockHeightExp
        : cbgHeightExpn;
    final precinctCount = resolution.pw * resolution.ph;
    for (var precinctNo = 0; precinctNo < precinctCount; precinctNo++) {
      final cbgX = cbgBaseX + (precinctNo % resolution.pw) * (1 << cbgWidthExpn);
      final cbgY = cbgBaseY + (precinctNo ~/ resolution.pw) * (1 << cbgHeightExpn);
      final prcX0 = cbgX > band.x0 ? cbgX : band.x0;
      final prcY0 = cbgY > band.y0 ? cbgY : band.y0;
      final prcX1 = (cbgX + (1 << cbgWidthExpn)).clamp(prcX0, band.x1);
      final prcY1 = (cbgY + (1 << cbgHeightExpn)).clamp(prcY0, band.y1);
      final gridX0 = _floorDivPow2(prcX0, cblkWidthExpn) << cblkWidthExpn;
      final gridY0 = _floorDivPow2(prcY0, cblkHeightExpn) << cblkHeightExpn;
      final gridX1 = _ceilDivPow2(prcX1, cblkWidthExpn) << cblkWidthExpn;
      final gridY1 = _ceilDivPow2(prcY1, cblkHeightExpn) << cblkHeightExpn;
      final cw = prcX1 <= prcX0 ? 0 : (gridX1 - gridX0) >> cblkWidthExpn;
      final ch = prcY1 <= prcY0 ? 0 : (gridY1 - gridY0) >> cblkHeightExpn;
      final precinct = _Precinct(prcX0, prcY0, prcX1, prcY1, cw, ch);
      for (var cblkNo = 0; cblkNo < cw * ch; cblkNo++) {
        final cblk = precinct.cblks[cblkNo];
        final startX = gridX0 + (cblkNo % cw) * (1 << cblkWidthExpn);
        final startY = gridY0 + (cblkNo ~/ cw) * (1 << cblkHeightExpn);
        cblk.x0 = startX > band.x0 ? startX : band.x0;
        cblk.y0 = startY > band.y0 ? startY : band.y0;
        cblk.x1 = (startX + (1 << cblkWidthExpn)).clamp(cblk.x0, band.x1);
        cblk.y1 = (startY + (1 << cblkHeightExpn)).clamp(cblk.y0, band.y1);
      }
      band.precincts.add(precinct);
    }
  }

  void _assembleTileData() {
    var total = 0;
    for (final part in info.tileParts) {
      if (part.tileIndex == tileIndex) {
        total += part.dataLength;
      }
    }
    if (total == 0) {
      throw const JpxException('JPEG 2000 tile has no packet data.');
    }
    if (total > kJpxMaxInputBytes) {
      throw JpxException(kJpxBudgetMessage);
    }
    _data = Uint8List(total);
    var cursor = 0;
    for (final part in info.tileParts) {
      if (part.tileIndex != tileIndex) {
        continue;
      }
      _data.setRange(
        cursor,
        cursor + part.dataLength,
        Uint8List.sublistView(codestream, part.dataStart, part.dataStart + part.dataLength),
      );
      cursor += part.dataLength;
    }
  }

  // -- Packet scheduling (tier 2) -----------------------------------------

  int _bodyReserve = 0;

  void _runPackets() {
    final shared = info.componentCoding[0];
    final layerCount = shared.layerCount;
    final numres = shared.decompositionLevels + 1;
    final byRlcp = shared.progressionOrder == kProgressionRlcp;
    final useSop = shared.usesSop;
    final useEph = shared.usesEph;
    _cursor = 0;

    void runPrecinctPacket(
      final int layer,
      final int resno,
      final int component,
      final int precinctNo,
    ) {
      final resolution = _components[component].resolutions[resno];
      final coding = info.componentCoding[component];
      if (useSop &&
          _cursor + 6 <= _data.length &&
          _data[_cursor] == 0xFF &&
          _data[_cursor + 1] == 0x91) {
        _cursor += 6;
      }
      if (_cursor >= _data.length) {
        throw const JpxException('JPEG 2000 tile runs out of packets.');
      }
      final reader = JpxBitReader(_data, _cursor, _data.length - _cursor);
      if (layer == 0) {
        // The layer-0 packet re-arms only its own precinct's tag trees
        // and code-block state (OpenJPEG resets per packet, not per
        // resolution).
        for (final band in resolution.bands) {
          if (band.isEmpty) {
            continue;
          }
          final precinct = band.precincts[precinctNo];
          precinct.inclusion.reset();
          precinct.imsb.reset();
          for (final cblk in precinct.cblks) {
            cblk.segments.clear();
            cblk.open = -1;
            cblk.seen = false;
          }
        }
      }
      final pending = <_PendingBody>[];
      if (reader.read(1) == 0) {
        reader.align();
        _cursor += reader.consumed;
        if (useEph) {
          _expectEph();
        }
        return;
      }
      for (final band in resolution.bands) {
        if (band.isEmpty) {
          continue;
        }
        final precinct = band.precincts[precinctNo];
        for (var cblkNo = 0; cblkNo < precinct.cblks.length; cblkNo++) {
          final cblk = precinct.cblks[cblkNo];
          int included;
          if (!cblk.seen) {
            included = precinct.inclusion.decode(reader, cblkNo, layer + 1);
          } else {
            included = reader.read(1);
          }
          if (included == 0) {
            continue;
          }
          if (!cblk.seen) {
            var zeroPlanes = 0;
            while (precinct.imsb.decode(reader, cblkNo, zeroPlanes) == 0) {
              zeroPlanes++;
              if (zeroPlanes > band.numbps + 1) {
                throw const JpxException('JPEG 2000 zero-bitplane tag tree is unbounded.');
              }
            }
            cblk.numbps = band.numbps + 1 - zeroPlanes;
            cblk.numlenBits = 3;
            cblk.segments.clear();
            cblk.open = -1;
          }
          cblk.seen = true;
          final newPasses = _readPassCount(reader);
          final comma = _readCommaCode(reader);
          cblk.numlenBits += comma;
          if (cblk.numlenBits > 30) {
            throw const JpxException('JPEG 2000 length indicator is out of range.');
          }
          if (cblk.open < 0 ||
              cblk.segments[cblk.open].passes == cblk.segments[cblk.open].maxPasses) {
            _startSegment(cblk, coding);
          }
          var remaining = newPasses;
          while (remaining > 0) {
            final segment = cblk.segments[cblk.open];
            final capacity = segment.maxPasses - segment.passes;
            final take = remaining < capacity ? remaining : capacity;
            if (take <= 0) {
              throw const JpxException('JPEG 2000 code-block segment capacity is exhausted.');
            }
            final bits = cblk.numlenBits + _floorLog2(take);
            if (bits > 31) {
              throw const JpxException('JPEG 2000 packet length field is out of range.');
            }
            final length = reader.read(bits);
            pending.add(_PendingBody(segment, _bodyReserve, length, take));
            _bodyReserve += length;
            remaining -= take;
            if (remaining > 0) {
              _startSegment(cblk, coding);
            }
          }
        }
      }
      reader.align();
      _cursor += reader.consumed;
      if (useEph) {
        _expectEph();
      }
      final bodyStart = _cursor;
      if (_bodyReserve > _data.length - bodyStart) {
        throw const JpxException('JPEG 2000 packet body exceeds the tile-part.');
      }
      for (final write in pending) {
        final segment = write.segment;
        segment.chunks.add((bodyStart + write.relativeStart, write.length));
        segment.length += write.length;
        segment.passes += write.passes;
      }
      _cursor += _bodyReserve;
      _bodyReserve = 0;
    }

    if (byRlcp) {
      for (var resno = 0; resno < numres; resno++) {
        for (var layer = 0; layer < layerCount; layer++) {
          for (var component = 0; component < _componentCount; component++) {
            final resolution = _components[component].resolutions[resno];
            for (var precinctNo = 0; precinctNo < resolution.pw * resolution.ph; precinctNo++) {
              runPrecinctPacket(layer, resno, component, precinctNo);
            }
          }
        }
      }
    } else {
      for (var layer = 0; layer < layerCount; layer++) {
        for (var resno = 0; resno < numres; resno++) {
          for (var component = 0; component < _componentCount; component++) {
            final resolution = _components[component].resolutions[resno];
            for (var precinctNo = 0; precinctNo < resolution.pw * resolution.ph; precinctNo++) {
              runPrecinctPacket(layer, resno, component, precinctNo);
            }
          }
        }
      }
    }
  }

  void _expectEph() {
    if (_cursor + 2 > _data.length || _data[_cursor] != 0xFF || _data[_cursor + 1] != 0x92) {
      throw const JpxException('Expected EPH marker after a packet header.');
    }
    _cursor += 2;
  }

  int _readCommaCode(final JpxBitReader reader) {
    var count = 0;
    while (reader.read(1) == 1) {
      count++;
      if (count > 30) {
        throw const JpxException('JPEG 2000 comma code is unbounded.');
      }
    }
    return count;
  }

  int _readPassCount(final JpxBitReader reader) {
    if (reader.read(1) == 0) {
      return 1;
    }
    if (reader.read(1) == 0) {
      return 2;
    }
    final two = reader.read(2);
    if (two != 3) {
      return 3 + two;
    }
    final five = reader.read(5);
    if (five != 31) {
      return 6 + five;
    }
    return 37 + reader.read(7);
  }

  int _floorLog2(final int value) {
    var result = -1;
    var rest = value;
    while (rest > 0) {
      rest >>= 1;
      result++;
    }
    return result;
  }

  void _startSegment(final _Codeblock cblk, final JpxComponentCoding coding) {
    final style = coding.codeblockStyle;
    final segment = _Segment();
    if (style & kJpxCblkStyleTerminate != 0) {
      segment.maxPasses = 1;
    } else if (style & kJpxCblkStyleBypass != 0) {
      if (cblk.segments.isEmpty) {
        segment.maxPasses = 10;
      } else {
        final previous = cblk.segments.last.maxPasses;
        segment.maxPasses = (previous == 1 || previous == 10) ? 2 : 1;
      }
    } else {
      segment.maxPasses = 109;
    }
    cblk.segments.add(segment);
    cblk.open = cblk.segments.length - 1;
  }

  // -- Tier 1, dequantization, DWT, MCT, level shift -----------------------

  List<Uint8List> _decodeTile() {
    final buffers = <TypedData>[];
    final flags = <bool>[];
    for (var component = 0; component < _componentCount; component++) {
      final coding = info.componentCoding[component];
      final tileComponent = _components[component];
      final numres = tileComponent.resolutions.length;
      final last = tileComponent.resolutions[numres - 1];
      final width = last.x1 - last.x0;
      final height = last.y1 - last.y0;
      final samples = checkedProduct(width, height);
      final irreversible = coding.transform == kTransformIrreversible;
      final buffer = irreversible ? Float32List(samples) : Int32List(samples);

      _decodeComponentCodeblocks(coding, tileComponent, buffer, irreversible);
      if (numres > 1) {
        JpxDwt.inverse(
          buffer: buffer,
          irreversible: irreversible,
          resolutionBounds: <(int, int, int, int)>[
            for (final r in tileComponent.resolutions) (r.x0, r.y0, r.x1, r.y1),
          ],
          width: width,
        );
      }
      buffers.add(buffer);
      flags.add(irreversible);
    }
    if (info.componentCoding[0].multiComponentTransform != 0 && buffers.length == 3) {
      JpxMct.inverse(buffers, flags[0]);
    }
    final output = <Uint8List>[];
    for (var component = 0; component < buffers.length; component++) {
      output.add(_levelShiftAndClip(buffers[component], flags[component]));
    }
    return output;
  }

  void _decodeComponentCodeblocks(
    final JpxComponentCoding coding,
    final _TileComponent tileComponent,
    final TypedData buffer,
    final bool irreversible,
  ) {
    final numres = tileComponent.resolutions.length;
    for (var resno = 0; resno < numres; resno++) {
      final resolution = tileComponent.resolutions[resno];
      for (final band in resolution.bands) {
        if (band.isEmpty) {
          continue;
        }
        var extraX = 0;
        var extraY = 0;
        if (band.orientation & 1 != 0) {
          final previous = tileComponent.resolutions[resno - 1];
          extraX = previous.x1 - previous.x0;
        }
        if (band.orientation & 2 != 0) {
          final previous = tileComponent.resolutions[resno - 1];
          extraY = previous.y1 - previous.y0;
        }
        final halfStep = irreversible ? _toFloat32(0.5 * band.stepSize) : 0.0;
        for (final precinct in band.precincts) {
          for (final cblk in precinct.cblks) {
            if (cblk.segments.isEmpty) {
              continue;
            }
            final cblkWidth = cblk.x1 - cblk.x0;
            final cblkHeight = cblk.y1 - cblk.y0;
            if (cblkWidth <= 0 || cblkHeight <= 0) {
              continue;
            }
            // Multi-layer packets contribute separate, non-contiguous
            // chunks per code-block; OpenJPEG concatenates them before
            // tier 1, with each segment becoming a span of the merged
            // buffer.
            var totalLength = 0;
            for (final segment in cblk.segments) {
              totalLength += segment.length;
            }
            final merged = Uint8List(totalLength);
            final segments = <JpxSegment>[];
            var writePosition = 0;
            for (final segment in cblk.segments) {
              for (final (chunkStart, chunkLength) in segment.chunks) {
                merged.setRange(
                  writePosition,
                  writePosition + chunkLength,
                  Uint8List.sublistView(_data, chunkStart, chunkStart + chunkLength),
                );
                writePosition += chunkLength;
              }
              segments.add(
                JpxSegment(writePosition - segment.length, segment.length, segment.passes),
              );
            }
            final coefficients = JpxTier1.decodeCblk(
              data: merged,
              segments: segments,
              width: cblkWidth,
              height: cblkHeight,
              orientation: band.orientation,
              numbps: cblk.numbps,
              cblkStyle: coding.codeblockStyle,
              roiShift: 0,
            );
            final rowBase =
                (cblk.y0 - band.y0 + extraY) * _tileWidth + (cblk.x0 - band.x0 + extraX);
            if (irreversible) {
              final target = buffer as Float32List;
              for (var row = 0; row < cblkHeight; row++) {
                final targetBase = rowBase + row * _tileWidth;
                final sourceBase = row * cblkWidth;
                for (var column = 0; column < cblkWidth; column++) {
                  target[targetBase + column] = _toFloat32(
                    coefficients[sourceBase + column].toDouble() * halfStep,
                  );
                }
              }
            } else {
              final target = buffer as Int32List;
              for (var row = 0; row < cblkHeight; row++) {
                final targetBase = rowBase + row * _tileWidth;
                final sourceBase = row * cblkWidth;
                for (var column = 0; column < cblkWidth; column++) {
                  final value = coefficients[sourceBase + column];
                  target[targetBase + column] = value < 0 ? -((-value) ~/ 2) : value ~/ 2;
                }
              }
            }
          }
        }
      }
    }
  }

  static double _toFloat32(final double value) {
    final f32 = Float32List(1)..[0] = value;
    return f32[0];
  }

  Uint8List _levelShiftAndClip(final TypedData buffer, final bool irreversible) {
    final samples = buffer is Float32List ? buffer.length : (buffer as Int32List).length;
    final out = Uint8List(samples);
    // Unsigned components carry a DC level shift the decoder adds back
    // (OpenJPEG sets m_dc_level_shift = 1 << (prec - 1)).
    const dcShift = 1 << 7;
    for (var index = 0; index < samples; index++) {
      int value;
      if (irreversible) {
        value = _roundHalfEven((buffer as Float32List)[index]) + dcShift;
      } else {
        value = (buffer as Int32List)[index] + dcShift;
      }
      out[index] = value < 0 ? 0 : (value > 255 ? 255 : value);
    }
    return out;
  }

  /// Rounds half to even like OpenJPEG's `opj_lrintf`.
  static int _roundHalfEven(final double value) {
    final floor = value.floorToDouble();
    final fraction = value - floor;
    final lower = floor.toInt();
    if (fraction > 0.5) {
      return lower + 1;
    }
    if (fraction < 0.5) {
      return lower;
    }
    return lower.isEven ? lower : lower + 1;
  }
}
