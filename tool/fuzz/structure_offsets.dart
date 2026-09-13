import 'dart:typed_data';

/// The container family guessed from a seed fixture's magic bytes.
enum SeedContainer {
  /// ZIP local header `PK\x03\x04` found (EPUB, CBZ, DOCX, ODT, HTMLZ, TXTZ...).
  zip,

  /// `%PDF` header found.
  pdf,

  /// PalmDB header (Palm name + `BOOKMOBI`/`TEXtREAd`/... at offset 60).
  palmDb,

  /// No known container signature.
  unknown,
}

/// One structurally interesting byte offset in a seed fixture.
final class StructureOffset {
  const StructureOffset(this.name, this.offset);

  /// Stable short label, e.g. `eocd`, `central-directory-3`, `pdb-record-5`.
  final String name;

  /// Byte offset into the fixture.
  final int offset;

  @override
  String toString() => '$name@$offset';
}

/// The result of scanning a seed fixture for structurally interesting offsets.
///
/// Truncation and mutation cases are anchored on these offsets so the
/// generated cases cluster around the places parsers actually branch on
/// (EOCD, central directory, xref, `%%EOF`, PalmDB record boundaries)
/// instead of uniform noise.
final class StructureScan {
  const StructureScan._(this.container, this.offsets, this.length);

  /// Guessed container family.
  final SeedContainer container;

  /// Interesting offsets, sorted ascending by offset.
  final List<StructureOffset> offsets;

  /// Total fixture length in bytes.
  final int length;

  /// Scans [bytes] for container signatures and interesting offsets.
  static StructureScan scan(final Uint8List bytes) {
    final container = _guessContainer(bytes);
    final offsets = <StructureOffset>[];
    switch (container) {
      case SeedContainer.zip:
        _scanZip(bytes, offsets);
      case SeedContainer.pdf:
        _scanPdf(bytes, offsets);
      case SeedContainer.palmDb:
        _scanPalmDb(bytes, offsets);
      case SeedContainer.unknown:
        _scanGeneric(bytes, offsets);
    }
    offsets.sort((final a, final b) => a.offset.compareTo(b.offset));
    return StructureScan._(container, offsets, bytes.length);
  }

  /// Offsets at least [margin] bytes away from either end of the fixture.
  List<StructureOffset> within(final int margin) =>
      offsets.where((final o) => o.offset >= margin && o.offset <= length - margin).toList();

  static SeedContainer _guessContainer(final Uint8List bytes) {
    if (_find(bytes, _eocd, 0) != null || _find(bytes, _centralDir, 0) != null) {
      return SeedContainer.zip;
    }
    if (_find(bytes, _pdfHeader, 0) != null) {
      return SeedContainer.pdf;
    }
    if (bytes.length >= 78 && _looksLikePalmDbType(bytes)) {
      return SeedContainer.palmDb;
    }
    return SeedContainer.unknown;
  }

  /// PalmDB files carry two 4-byte ASCII type/creator fields at offset 60.
  static bool _looksLikePalmDbType(final Uint8List bytes) {
    for (var i = 60; i < 68; i++) {
      final byte = bytes[i];
      final printable = byte >= 0x20 && byte < 0x7F;
      if (!printable && byte != 0) {
        return false;
      }
    }
    final typeHasContent = bytes.sublist(60, 64).any((final b) => b != 0);
    return typeHasContent;
  }

  static void _scanZip(final Uint8List bytes, final List<StructureOffset> offsets) {
    var cursor = 0;
    var localCount = 0;
    var centralCount = 0;
    while (cursor + 4 <= bytes.length) {
      final found = _find(bytes, _localHeader, cursor);
      if (found == null) {
        break;
      }
      offsets.add(StructureOffset('local-header-$localCount', found));
      localCount++;
      cursor = found + 4;
    }
    cursor = 0;
    while (cursor + 4 <= bytes.length) {
      final found = _find(bytes, _centralDir, cursor);
      if (found == null) {
        break;
      }
      offsets.add(StructureOffset('central-directory-$centralCount', found));
      centralCount++;
      cursor = found + 4;
    }
    final eocd = _find(bytes, _eocd, 0);
    if (eocd != null) {
      offsets.add(StructureOffset('eocd', eocd));
    }
  }

  static void _scanPdf(final Uint8List bytes, final List<StructureOffset> offsets) {
    void scanFor(final List<int> marker, final String prefix) {
      var cursor = 0;
      var count = 0;
      while (cursor + marker.length <= bytes.length) {
        final found = _find(bytes, marker, cursor);
        if (found == null) {
          break;
        }
        offsets.add(StructureOffset('$prefix-$count', found));
        count++;
        cursor = found + marker.length;
      }
    }

    scanFor(_pdfHeader, 'pdf-header');
    scanFor(_xrefKeyword, 'xref');
    scanFor(_startxref, 'startxref');
    scanFor(_trailerKeyword, 'trailer');
    scanFor(_streamKeyword, 'stream');
    scanFor(_endstream, 'endstream');
    scanFor(_eofMarker, 'eof');
    _scanPdfObjects(bytes, offsets);
  }

  static void _scanPdfObjects(final Uint8List bytes, final List<StructureOffset> offsets) {
    // Finds "N G obj" object headers: walks back from each " obj" over the
    // generation number and the object number.
    const needle = ' obj';
    var count = 0;
    var cursor = 0;
    while (cursor + needle.length <= bytes.length) {
      final found = _find(bytes, needle.codeUnits, cursor);
      if (found == null) {
        break;
      }
      var p = found - 1;
      while (p >= 0 && _isSpace(bytes[p])) {
        p--;
      }
      var hasGeneration = false;
      while (p >= 0 && _isDigit(bytes[p])) {
        p--;
        hasGeneration = true;
      }
      while (p >= 0 && _isSpace(bytes[p])) {
        p--;
      }
      var hasObjectNumber = false;
      while (p >= 0 && _isDigit(bytes[p])) {
        p--;
        hasObjectNumber = true;
      }
      if (hasGeneration && hasObjectNumber) {
        offsets.add(StructureOffset('obj-$count', p + 1));
        count++;
      }
      cursor = found + needle.length;
    }
  }

  static bool _isDigit(final int byte) => byte >= 0x30 && byte <= 0x39;

  static void _scanPalmDb(final Uint8List bytes, final List<StructureOffset> offsets) {
    if (bytes.length < 78) {
      return;
    }
    final recordCount = (bytes[76] << 8) | bytes[77];
    // Sanity: record lists of real PalmDB files are small relative to size;
    // garbage counts (0 or > 10000) mean this is not actually a PalmDB.
    if (recordCount == 0 || recordCount > 10000 || 78 + recordCount * 8 > bytes.length) {
      return;
    }
    offsets.add(const StructureOffset('pdb-header', 0));
    for (var i = 0; i < recordCount; i++) {
      final base = 78 + i * 8;
      final recordOffset =
          (bytes[base] << 24) | (bytes[base + 1] << 16) | (bytes[base + 2] << 8) | bytes[base + 3];
      if (recordOffset < bytes.length) {
        offsets.add(StructureOffset('pdb-record-$i', recordOffset));
      }
    }
  }

  static void _scanGeneric(final Uint8List bytes, final List<StructureOffset> offsets) {
    scanMarker(bytes, offsets, _eofMarker, 'eof');
    scanMarker(bytes, offsets, _xmlDecl, 'xml-decl');
  }

  /// Scans [bytes] for every occurrence of [marker], appending named offsets.
  static void scanMarker(
    final Uint8List bytes,
    final List<StructureOffset> offsets,
    final List<int> marker,
    final String prefix,
  ) {
    var cursor = 0;
    var count = 0;
    while (cursor + marker.length <= bytes.length) {
      final found = _find(bytes, marker, cursor);
      if (found == null) {
        break;
      }
      offsets.add(StructureOffset('$prefix-$count', found));
      count++;
      cursor = found + marker.length;
    }
  }

  static bool _isSpace(final int byte) =>
      byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D;

  static int? _find(final Uint8List bytes, final List<int> needle, final int from) {
    if (needle.isEmpty || bytes.length < needle.length) {
      return null;
    }
    for (var i = from; i <= bytes.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        return i;
      }
    }
    return null;
  }

  static const List<int> _localHeader = [0x50, 0x4B, 0x03, 0x04];
  static const List<int> _centralDir = [0x50, 0x4B, 0x01, 0x02];
  static const List<int> _eocd = [0x50, 0x4B, 0x05, 0x06];
  static const List<int> _pdfHeader = [0x25, 0x50, 0x44, 0x46]; // %PDF
  static final List<int> _xrefKeyword = 'xref'.codeUnits;
  static final List<int> _startxref = 'startxref'.codeUnits;
  static final List<int> _trailerKeyword = 'trailer'.codeUnits;
  static final List<int> _streamKeyword = 'stream'.codeUnits;
  static final List<int> _endstream = 'endstream'.codeUnits;
  static final List<int> _eofMarker = '%%EOF'.codeUnits;
  static final List<int> _xmlDecl = '<?xml'.codeUnits;
}
