import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A PDF object under construction (streaming or plain).
final class PdfObjectSpec {
  const PdfObjectSpec._(
    this.number,
    this.dictionary,
    this.streamPayload, [
    this.streamFilter = PdfStreamFilter.none,
  ]);

  /// Plain (non-stream) object from [dictionary] text.
  factory PdfObjectSpec.plain(final int number, final String dictionary) =>
      PdfObjectSpec._(number, dictionary, null);

  /// Stream object whose dictionary gets /Length and optional /Filter.
  factory PdfObjectSpec.stream(
    final int number,
    final String dictionary,
    final List<int> payload, {
    final PdfStreamFilter filter = PdfStreamFilter.none,
  }) => PdfObjectSpec._(number, dictionary, payload, filter);

  /// Object number (generation is always 0 in generated fixtures).
  final int number;

  /// Dictionary body text WITHOUT the stream keys added automatically.
  final String dictionary;

  /// Stream payload (pre-filter bytes).
  final List<int>? streamPayload;

  /// Filter applied to the payload when serialized.
  final PdfStreamFilter streamFilter;
}

/// Stream filters supported by the generator.
enum PdfStreamFilter {
  /// No /Filter entry; payload is emitted verbatim.
  none,

  /// /FlateDecode with a standard zlib header.
  flate,

  /// /LZWDecode with EarlyChange=1 (Acrobat-compatible).
  lzw,
}

/// Serializes a full PDF document: header, objects, xref table, trailer.
///
/// Deterministic: object order is the list order, xref offsets are
/// computed from actual byte positions, and no timestamps are written.
Uint8List buildPdf(final List<PdfObjectSpec> objects, {final String? infoDictionary}) {
  final out = BytesBuilder(copy: false);
  // Header plus the 4 binary-comment bytes that mark the file as containing
  // binary (>127) data; written as raw bytes, not UTF-8 re-encoded.
  out.add(utf8.encode('%PDF-1.4\n%'));
  out.add(const [0xE2, 0xE3, 0xCF, 0xD3]);
  out.add(const [0x0A]);

  final offsets = <int>[];
  for (final object in objects) {
    offsets.add(out.length);
    out.add(utf8.encode('${object.number} 0 obj\n'));
    if (object.streamPayload == null) {
      out.add(utf8.encode('${object.dictionary}\n'));
    } else {
      final filtered = _applyFilter(object.streamPayload!, object.streamFilter);
      final filterEntry = object.streamFilter == PdfStreamFilter.none
          ? ''
          : object.streamFilter == PdfStreamFilter.flate
          ? ' /Filter /FlateDecode'
          : ' /Filter /LZWDecode /DecodeParms << /EarlyChange 1 >>';
      // /Length (and the filter) go INSIDE the dictionary: the stream
      // keyword must directly follow the closing >> for strict parsers.
      final body = object.dictionary;
      final close = body.lastIndexOf('>>');
      final patched = close < 0
          ? '$body$filterEntry /Length ${filtered.length} >>'
          : '${body.substring(0, close)}$filterEntry /Length ${filtered.length}${body.substring(close)}';
      out.add(utf8.encode('$patched\n'));
      out.add(utf8.encode('stream\n'));
      out.add(filtered);
      out.add(utf8.encode('\nendstream\n'));
    }
    out.add(utf8.encode('endobj\n'));
  }

  final xrefOffset = out.length;
  final maxNumber = objects.map((final o) => o.number).reduce((final a, final b) => a > b ? a : b);
  final slots = List<int?>.filled(maxNumber + 1, null);
  for (var i = 0; i < objects.length; i++) {
    slots[objects[i].number] = offsets[i];
  }
  // Slot 0 is the head of the free list, always emitted as free.
  final xref = StringBuffer('xref\n0 ${slots.length}\n');
  for (final slot in slots) {
    if (slot == null) {
      xref.write('0000000000 65535 f \n');
    } else {
      xref.write('${slot.toString().padLeft(10, '0')} 00000 n \n');
    }
  }
  final trailerDict = infoDictionary ?? '<< /Size ${slots.length} /Root 1 0 R >>';
  xref.write('trailer\n$trailerDict\nstartxref\n$xrefOffset\n%%EOF\n');
  out.add(utf8.encode(xref.toString()));
  return out.toBytes();
}

/// A complete minimal single-page text PDF.
Uint8List minimalTextPdf({
  final String text = 'Fuzz corpus page',
  final PdfStreamFilter filter = PdfStreamFilter.none,
}) {
  final content = 'BT /F1 12 Tf 72 720 Td (${_escape(text)}) Tj ET';
  return buildPdf([
    PdfObjectSpec.plain(1, '<< /Type /Catalog /Pages 2 0 R >>'),
    PdfObjectSpec.plain(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    PdfObjectSpec.plain(
      3,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    ),
    PdfObjectSpec.plain(4, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
    PdfObjectSpec.stream(5, '<< >>', utf8.encode(content), filter: filter),
  ]);
}

/// A two-page PDF whose content streams use [filter].
Uint8List twoPagePdf(final PdfStreamFilter filter) {
  final content1 = utf8.encode('BT /F1 12 Tf 72 720 Td (First page) Tj ET');
  final content2 = utf8.encode('BT /F1 12 Tf 72 720 Td (Second page) Tj ET');
  return buildPdf([
    PdfObjectSpec.plain(1, '<< /Type /Catalog /Pages 2 0 R >>'),
    PdfObjectSpec.plain(2, '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>'),
    PdfObjectSpec.plain(
      3,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>',
    ),
    PdfObjectSpec.plain(
      4,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>',
    ),
    PdfObjectSpec.plain(5, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
    PdfObjectSpec.stream(6, '<< >>', content1, filter: filter),
    PdfObjectSpec.stream(7, '<< >>', content2, filter: filter),
  ]);
}

/// PDF whose Info dictionary carries synthetic metadata fields.
Uint8List pdfWithInfo({
  final String title = 'Sanitized Fixture',
  final String author = 'Anonymized Author',
}) {
  final trailer = '<< /Size 7 /Root 1 0 R /Info 6 0 R >>';
  final content = utf8.encode('BT /F1 12 Tf 72 720 Td (Info test) Tj ET');
  return buildPdf([
    PdfObjectSpec.plain(1, '<< /Type /Catalog /Pages 2 0 R >>'),
    PdfObjectSpec.plain(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    PdfObjectSpec.plain(
      3,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    ),
    PdfObjectSpec.plain(4, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
    PdfObjectSpec.stream(5, '<< >>', content),
    PdfObjectSpec.plain(
      6,
      '<< /Title (${_escape(title)}) /Author (${_escape(author)}) /Producer (fuzz-corpus-generator) >>',
    ),
  ], infoDictionary: trailer);
}

Uint8List _applyFilter(final List<int> payload, final PdfStreamFilter filter) => switch (filter) {
  PdfStreamFilter.none => Uint8List.fromList(payload),
  PdfStreamFilter.flate => Uint8List.fromList(ZLibEncoder(level: 6).convert(payload)),
  PdfStreamFilter.lzw => lzwEncode(payload),
};

String _escape(final String text) =>
    text.replaceAll('\\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

// --- LZW (PDF flavor, EarlyChange=1) ---

/// Encodes [data] with PDF LZW: 9-12 bit codes, code 256 = clear,
/// 257 = EOD, table grows one code EARLY (EarlyChange=1) as Acrobat
/// and the PDF spec default require.
Uint8List lzwEncode(final List<int> data) {
  final out = BitsWriter();
  var codeWidth = 9;
  var nextCode = 258;
  final table = <String, int>{};
  void resetTable() {
    table
      ..clear()
      // Single-byte roots: codes 0-255 are implicit literals in LZW.
      ..addEntries(
        List<MapEntry<String, int>>.generate(256, (final i) => MapEntry(String.fromCharCode(i), i)),
      );
    nextCode = 258;
    codeWidth = 9;
  }

  resetTable();
  out.write(256, codeWidth); // clear code first

  var prefix = '';
  for (final byte in data) {
    final candidate = prefix + String.fromCharCode(byte);
    final existing = table[candidate];
    if (existing != null) {
      prefix = candidate;
      continue;
    }
    // Emit the code for the longest known prefix.
    final prefixCode = prefix.isEmpty ? byte : table[prefix]!;
    out.write(prefixCode, codeWidth);
    // EarlyChange: grow the code width when the NEXT code would be 511/1023/2047.
    table[candidate] = nextCode;
    nextCode++;
    if (nextCode + 1 >= (1 << codeWidth) && codeWidth < 12) {
      codeWidth++;
    }
    if (nextCode >= 4096) {
      out.write(256, codeWidth);
      resetTable();
    }
    prefix = String.fromCharCode(byte);
  }
  if (prefix.isNotEmpty) {
    out.write(prefix.isEmpty ? 0 : (table[prefix] ?? prefix.codeUnitAt(0)), codeWidth);
  }
  out.write(257, codeWidth); // EOD
  return out.toBytes();
}

/// MSB-first bit writer.
final class BitsWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _accumulator = 0;
  int _bits = 0;

  /// Writes [value] using [width] bits, most significant bit first.
  void write(final int value, final int width) {
    _accumulator = (_accumulator << width) | value;
    _bits += width;
    while (_bits >= 8) {
      _builder.addByte((_accumulator >> (_bits - 8)) & 0xFF);
      _bits -= 8;
    }
    _accumulator &= (1 << _bits) - 1;
  }

  /// Flushes padding bits and returns the encoded bytes.
  Uint8List toBytes() {
    if (_bits > 0) {
      _builder.addByte((_accumulator << (8 - _bits)) & 0xFF | 0);
      _bits = 0;
    }
    return _builder.toBytes();
  }
}
