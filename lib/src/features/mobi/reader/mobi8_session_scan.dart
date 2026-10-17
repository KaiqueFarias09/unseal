import 'dart:typed_data';

import '../codec/mobi_base32.dart';
import '../codec/mobi_byte_search.dart';

/// Byte-level open-pass scan of a KF8 text stream.
///
/// Runs inside the `MobiTextStore.build` record pass and collects the
/// two facts the session needs from the raw stream without keeping it:
///
/// * flow classification flags — whether each secondary flow opens an
///   SVG document (and whether that document carries an image element),
///   or holds a CDATA style block. The flags mirror the eager
///   `classifyMobi8Flow` decision on the whole flow bytes: `<svg`
///   opening plus a later `>` completes the SVG match, and the content
///   strips to the SVG opening.
/// * every quoted `kindle:pos:fid` reference, so the session can
///   resolve the complete linked-aid set at open and finalize any part
///   in any order with the eager markup outcome.
final class Mobi8SessionScan {
  /// Creates a scan over the FDST flow table's stream spans; entry 0
  /// (the XHTML flow) is excluded, so [flowSpans] lists the secondary
  /// flows in order.
  Mobi8SessionScan({required final List<(int, int)> flowSpans})
    : flows = List.generate(
        flowSpans.length,
        (final i) => Mobi8FlowFlags(flowSpans[i].$1, flowSpans[i].$2),
        growable: false,
      );

  /// Classification flags per secondary flow, in FDST order.
  final List<Mobi8FlowFlags> flows;

  /// Discovered `kindle:pos:fid` references as (fid, offset) pairs, in
  /// stream order.
  final List<(int, int)> posReferences = <(int, int)>[];

  Uint8List _buffer = Uint8List(0);
  var _bufferStart = 0;
  var _markerUpTo = 0;
  var _referenceUpTo = 0;

  /// Consumes one decompressed record chunk.
  void addRecord(final Uint8List chunk) {
    _buffer = Uint8List.fromList(<int>[..._buffer, ...chunk]);
    final start = _bufferStart;
    final end = start + _buffer.length;

    _scanPosReferences(start, end);
    _scanFlows(start, end);

    // Trim to the smallest window any scanner still owes work from.
    var keepFrom = _referenceUpTo < _markerUpTo ? _referenceUpTo : _markerUpTo;
    for (final flow in flows) {
      // A pending `>` search still owes bytes from its own cursor.
      final owed = flow.sawSvg && !flow.sawGt && flow.gtCheckedUpTo >= 0
          ? (flow.gtCheckedUpTo < flow.scannedUpTo ? flow.gtCheckedUpTo : flow.scannedUpTo)
          : flow.scannedUpTo;
      if (owed > start && owed < keepFrom) keepFrom = owed;
    }
    if (keepFrom > start) {
      final offset = keepFrom - start;
      _buffer = offset >= _buffer.length ? Uint8List(0) : Uint8List.sublistView(_buffer, offset);
      _bufferStart = keepFrom;
    }
  }

  /// Finishes the scan; the stream ended.
  void finish() {}

  void _scanPosReferences(final int start, final int end) {
    var i = _markerUpTo > start ? _markerUpTo - start : 0;
    while (true) {
      final at = _indexOfIgnoreCase(_buffer, _posFidMarker, i);
      if (at == -1) break;

      // The eager link pattern requires a quote before the reference.
      if (at > 0 && (_buffer[at - 1] == 0x22 || _buffer[at - 1] == 0x27)) {
        final reference = _parsePosReference(_buffer, at);
        if (reference != null) posReferences.add(reference);
      }
      i = at + 1;
    }
    _markerUpTo = end > _markerWindow ? end - _markerWindow : start;
    // References parse within a bounded window past the marker; the
    // cursor only reports markers from here on, so straddling
    // references are caught by the marker overlap next round.
    _referenceUpTo = _markerUpTo;
  }

  void _scanFlows(final int start, final int end) {
    for (final flow in flows) {
      if (end <= flow.start || start >= flow.end) continue;
      if (flow.scannedUpTo >= flow.end) continue;

      final from = flow.scannedUpTo > start ? flow.scannedUpTo - start : 0;
      final spanEnd = end < flow.end ? end : flow.end;
      _scanOneFlow(flow, from, start, spanEnd);
      flow.scannedUpTo = spanEnd;
    }
  }

  void _scanOneFlow(final Mobi8FlowFlags flow, final int from, final int start, final int end) {
    if (!flow.sawCdata) {
      final at = _indexOf(_buffer, _cdataMarker, from);
      if (at != -1 && start + at < flow.end) flow.sawCdata = true;
    }

    if (!flow.sawSvg) {
      final at = _indexOfIgnoreCase(_buffer, _svgMarker, from);
      if (at == -1) {
        _scanGt(flow, from, start, end);

        return;
      }

      flow.sawSvg = true;
      flow.svgStart = start + at;
      flow.gtCheckedUpTo = flow.svgStart + _svgMarker.length;
    }

    // An SVG image element counts only after the SVG opening, matching
    // the eager search inside the stripped document.
    var imageFrom = from;
    if (flow.gtCheckedUpTo > start + imageFrom) imageFrom = flow.gtCheckedUpTo - start;
    if (!flow.sawSvgImage) {
      final best = _firstIndexOf(_buffer, _svgImageMarkers, imageFrom);
      if (best != -1 && start + best > flow.svgStart) flow.sawSvgImage = true;
    }

    _scanGt(flow, from, start, end);
  }

  void _scanGt(final Mobi8FlowFlags flow, final int from, final int start, final int end) {
    if (!flow.sawSvg || flow.sawGt) return;

    var search = flow.gtCheckedUpTo > start ? flow.gtCheckedUpTo - start : from;
    if (search < 0) search = 0;
    final spanEnd = end < flow.end ? end : flow.end;
    final limit = spanEnd - start;
    if (search >= limit) {
      flow.gtCheckedUpTo = spanEnd;

      return;
    }
    final at = indexOfByte(_buffer, 0x3E, search);
    if (at != -1 && at < limit) {
      flow.sawGt = true;
      flow.gtCheckedUpTo = start + at + 1;
    } else {
      flow.gtCheckedUpTo = spanEnd;
    }
  }

  static final List<int> _posFidMarker = 'kindle:pos:fid:'.codeUnits;
  static final List<int> _offMarker = ':off:'.codeUnits;
  static final List<int> _svgMarker = '<svg'.codeUnits;
  static final List<int> _cdataMarker = '[CDATA['.codeUnits;
  static final List<List<int>> _svgImageMarkers = ['<image'.codeUnits, '<svg:image'.codeUnits];
  static final int _markerWindow = _posFidMarker.length + 40;

  static int _indexOf(final Uint8List data, final List<int> pattern, final int from) {
    outer:
    for (var i = from; i <= data.length - pattern.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) continue outer;
      }

      return i;
    }

    return -1;
  }

  static int _indexOfIgnoreCase(final Uint8List data, final List<int> pattern, final int from) {
    outer:
    for (var i = from; i <= data.length - pattern.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        var a = data[i + j];
        var b = pattern[j];
        if (a >= 0x41 && a <= 0x5A) a += 0x20;
        if (b >= 0x41 && b <= 0x5A) b += 0x20;
        if (a != b) continue outer;
      }

      return i;
    }

    return -1;
  }

  static int _firstIndexOf(final Uint8List data, final List<List<int>> patterns, final int from) {
    var best = -1;
    for (final pattern in patterns) {
      final at = _indexOfIgnoreCase(data, pattern, from);
      if (at != -1 && (best == -1 || at < best)) best = at;
    }

    return best;
  }

  /// Parses `N:off:M` after the marker at [at]. The eager pattern then
  /// requires non-quote bytes up to a closing quote; the scan accepts
  /// a closing quote within a bounded suffix window, which covers the
  /// attribute-value form every real reference uses.
  static (int, int)? _parsePosReference(final Uint8List data, final int at) {
    var i = at + _posFidMarker.length;
    final fidDigits = StringBuffer();
    while (i < data.length && _isBase32Byte(data[i])) {
      fidDigits.writeCharCode(data[i]);
      i++;
    }
    if (fidDigits.isEmpty) return null;
    if (!_hasAt(data, i, _offMarker)) return null;
    i += _offMarker.length;

    final offDigits = StringBuffer();
    while (i < data.length && _isBase32Byte(data[i])) {
      offDigits.writeCharCode(data[i]);
      i++;
    }
    if (offDigits.isEmpty) return null;

    // Closing quote within a small suffix (mime suffixes fit).
    final quoteLimit = i + 64 < data.length ? i + 64 : data.length;
    var closed = false;
    for (var q = i; q < quoteLimit; q++) {
      final byte = data[q];
      if (byte == 0x22 || byte == 0x27) {
        closed = true;
        break;
      }
    }
    if (!closed) return null;

    try {
      return (parseBase32(fidDigits.toString()), parseBase32(offDigits.toString()));
    } on Object {
      return null;
    }
  }

  static bool _hasAt(final Uint8List data, final int at, final List<int> pattern) {
    if (at + pattern.length > data.length) return false;

    for (var j = 0; j < pattern.length; j++) {
      if (data[at + j] != pattern[j]) return false;
    }

    return true;
  }
}

/// Classification flags of one secondary flow, mirroring the eager
/// `classifyMobi8Flow` decision points.
final class Mobi8FlowFlags {
  /// Creates the flags for the flow span [start, end).
  Mobi8FlowFlags(this.start, this.end);

  /// Inclusive stream start of the flow.
  final int start;

  /// Exclusive stream end of the flow.
  final int end;

  /// Stream offset the flag scan has consumed so far.
  var scannedUpTo = -1;

  /// An `<svg` opening appeared.
  bool sawSvg = false;

  /// Its stream offset (the eager classification strips to here).
  int svgStart = -1;

  /// A `>` completed the `<svg[^>]*>` match.
  bool sawGt = false;

  /// Stream offset the `>` search has consumed so far.
  int gtCheckedUpTo = -1;

  /// An SVG image element follows the SVG opening.
  bool sawSvgImage = false;

  /// A CDATA section appeared (inline style flow).
  bool sawCdata = false;
}

bool _isBase32Byte(final int byte) {
  final upper = byte >= 0x61 && byte <= 0x7A ? byte - 0x20 : byte;

  return (upper >= 0x30 && upper <= 0x39) || (upper >= 0x41 && upper <= 0x56);
}
