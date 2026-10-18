import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Assembles minimal-but-valid PDF documents byte by byte, the same
/// discipline as `mobi_fixture_builder.dart`: impractical to ship
/// binary fixtures for every structural variant, so the tests build
/// exactly the shape they need and run the real parser over it.
class PdfFixtureBuilder {
  final Map<int, String> _bodies = <int, String>{};
  final Map<int, String> _streamEntries = <int, String>{};
  final Map<int, Uint8List> _streamData = <int, Uint8List>{};
  final Map<int, bool> _streamFlate = <int, bool>{};
  final Map<int, String> _compressed = <int, String>{};

  /// Bytes allowed before the PDF header in a focused preamble fixture.
  List<int> prefix = const <int>[];
  String trailerExtra = '';
  bool corruptXref = false;

  /// Adds a plain indirect object whose [body] sits between `obj` and
  /// `endobj` — e.g. `<< /Type /Catalog /Pages 2 0 R >>`.
  void addObject(final int number, final String body) {
    _bodies[number] = body;
  }

  /// Adds a stream object; [extraEntries] appends to the dictionary
  /// (e.g. `/Subtype /Type0`), [data] is the raw payload and [flate]
  /// compresses it with an explicit `/Filter /FlateDecode`.
  void addStreamObject(
    final int number,
    final String extraEntries,
    final List<int> data, {
    final bool flate = false,
  }) {
    _streamEntries[number] = extraEntries;
    _streamData[number] = Uint8List.fromList(data);
    _streamFlate[number] = flate;
  }

  /// Adds a non-stream object packed inside the document's object
  /// stream (only meaningful for [build] with cross-reference
  /// streams).
  void addCompressedObject(final int number, final String body) {
    _compressed[number] = body;
  }

  /// Builds the document with a classic cross-reference table.
  Uint8List build() {
    final out = BytesBuilder(copy: false);
    out.add(prefix);
    out.add('%PDF-1.7\n%'.codeUnits);
    out.add([0xE2, 0xE3, 0xCF, 0xD3]);
    out.add([0x0A]);

    final offsets = <int, int>{};
    final numbers = <int>[..._bodies.keys, ..._streamData.keys]..sort();
    for (final number in numbers) {
      offsets[number] = out.length;
      out.add('$number 0 obj\n'.codeUnits);
      if (_streamData.containsKey(number)) {
        final data = _streamFlate[number] == true
            ? Uint8List.fromList(const ZLibEncoder().encode(_streamData[number]!))
            : _streamData[number]!;
        final filter = _streamFlate[number] == true ? ' /Filter /FlateDecode' : '';
        out.add('<< /Length ${data.length}${_streamEntries[number]}$filter >>\n'.codeUnits);
        out.add('stream\n'.codeUnits);
        out.add(data);
        out.add('\nendstream\n'.codeUnits);
      } else {
        out.add('${_bodies[number]}\n'.codeUnits);
      }
      out.add('endobj\n'.codeUnits);
    }

    final maxNumber = numbers.isEmpty ? 0 : numbers.last;
    final xrefOffset = out.length;
    out.add((corruptXref ? 'zref' : 'xref').codeUnits);
    out.add('\n0 ${maxNumber + 1}\n'.codeUnits);
    out.add('0000000000 65535 f \n'.codeUnits);
    for (var number = 1; number <= maxNumber; number++) {
      final offset = offsets[number];
      if (offset == null) {
        out.add('0000000000 65535 f \n'.codeUnits);
      } else {
        out.add('${offset.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
      }
    }
    out.add('trailer\n<< /Size ${maxNumber + 1} /Root 1 0 R$trailerExtra >>\n'.codeUnits);
    out.add('startxref\n$xrefOffset\n%%EOF'.codeUnits);

    return out.toBytes();
  }

  /// Builds the document with a PDF 1.5 cross-reference stream, a
  /// Flate-compressed `/XRef` object and every [addCompressedObject]
  /// entry packed into one `/ObjStm`.
  Uint8List buildWithXrefStream() {
    final out = BytesBuilder(copy: false);
    out.add(prefix);
    out.add('%PDF-1.7\n%'.codeUnits);
    out.add([0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final offsets = <int, int>{};
    final numbers = <int>[..._bodies.keys, ..._streamData.keys]..sort();
    for (final number in numbers) {
      offsets[number] = out.length;
      out.add('$number 0 obj\n'.codeUnits);
      if (_streamData.containsKey(number)) {
        final data = _streamFlate[number] == true
            ? Uint8List.fromList(const ZLibEncoder().encode(_streamData[number]!))
            : _streamData[number]!;
        final filter = _streamFlate[number] == true ? ' /Filter /FlateDecode' : '';
        out.add('<< /Length ${data.length}${_streamEntries[number]}$filter >>\n'.codeUnits);
        out.add('stream\n'.codeUnits);
        out.add(data);
        out.add('\nendstream\n'.codeUnits);
      } else {
        out.add('${_bodies[number]}\n'.codeUnits);
      }
      out.add('endobj\n'.codeUnits);
    }

    // Object stream: number/relative-offset pairs then the bodies.
    var objectStreamNumber = 0;
    final compressedNumbers = _compressed.keys.toList()..sort();
    if (compressedNumbers.isNotEmpty) {
      objectStreamNumber = (numbers.isEmpty ? 0 : numbers.last) + 1;
      offsets[objectStreamNumber] = out.length;
      final header = StringBuffer();
      final bodies = StringBuffer();
      for (final number in compressedNumbers) {
        final body = _compressed[number]!;
        header.write('$number ${bodies.length} ');
        bodies.write(body);
        bodies.write(' ');
      }
      final firstOffset = header.length;
      final payload = Uint8List.fromList('$header$bodies'.codeUnits);
      out.add('$objectStreamNumber 0 obj\n'.codeUnits);
      out.add(
        '<< /N ${compressedNumbers.length} /First $firstOffset /Length ${payload.length} >>\n'
            .codeUnits,
      );
      out.add('stream\n'.codeUnits);
      out.add(payload);
      out.add('\nendstream\nendobj\n'.codeUnits);
    }

    // Cross-reference stream: type 1 offsets, type 2 object-stream
    // entries, itself last. /Index lists the runs of present numbers.
    final xrefNumber = objectStreamNumber == 0
        ? (numbers.isEmpty ? 0 : numbers.last) + 1
        : objectStreamNumber + 1;
    final size = xrefNumber + 1;
    final rows = BytesBuilder(copy: false);
    for (var number = 0; number < size; number++) {
      if (offsets.containsKey(number)) {
        rows.addByte(1);
        rows.add(_be(offsets[number]!, 4));
        rows.add(_be(0, 2));
      } else if (_compressed.containsKey(number)) {
        rows.addByte(2);
        rows.add(_be(objectStreamNumber, 4));
        rows.add(_be(compressedNumbers.indexOf(number), 2));
      } else {
        rows.addByte(0);
        rows.add(_be(0, 4));
        rows.add(_be(0, 2));
      }
    }

    final xrefOffset = out.length;
    final compressedRows = Uint8List.fromList(const ZLibEncoder().encode(rows.toBytes()));
    final index = _indexRuns(offsets, _compressed, size);
    out.add('$xrefNumber 0 obj\n'.codeUnits);
    out.add(
      '<< /Type /XRef /Size $size /W [1 4 2] /Index ${index.join(' ')} '
              '/Root 1 0 R$trailerExtra /Length ${compressedRows.length} '
              '/Filter /FlateDecode >>\n'
          .codeUnits,
    );
    out.add('stream\n'.codeUnits);
    out.add(compressedRows);
    out.add('\nendstream\nendobj\n'.codeUnits);
    out.add('startxref\n$xrefOffset\n%%EOF'.codeUnits);

    return out.toBytes();
  }

  /// `[start, count, start, count, ...]` runs over the numbers that
  /// hold an entry (offset or compressed).
  static List<int> _indexRuns(
    final Map<int, int> offsets,
    final Map<int, String> compressed,
    final int size,
  ) {
    final runs = <int>[];
    var runStart = -1;
    for (var number = 0; number < size; number++) {
      final present = offsets.containsKey(number) || compressed.containsKey(number);
      if (present && runStart < 0) {
        runStart = number;
      } else if (!present && runStart >= 0) {
        runs.addAll([runStart, number - runStart]);
        runStart = -1;
      }
    }
    if (runStart >= 0) {
      runs.addAll([runStart, size - runStart]);
    }

    return runs;
  }

  static List<int> _be(final int value, final int width) {
    final out = List<int>.filled(width, 0);
    var rest = value;
    for (var i = width - 1; i >= 0; i--) {
      out[i] = rest & 0xFF;
      rest >>= 8;
    }

    return out;
  }
}

/// The canonical two-page fixture: catalog, pages, empty content
/// streams, Info dictionary and (optionally) an outline.
PdfFixtureBuilder twoPageFixture({final bool withOutline = true}) {
  final fixture = PdfFixtureBuilder()
    ..addObject(
      1,
      withOutline
          ? '<< /Type /Catalog /Pages 2 0 R /Outlines 11 0 R >>'
          : '<< /Type /Catalog /Pages 2 0 R >>',
    )
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R 6 0 R] /Count 2 >>')
    ..addObject(
      3,
      '<</Title (Alice\x27s Adventures in Wonderland) /Author (Lewis Carroll & John Tenniel) '
      '/Creator (fixture writer) /Producer (unseal tests) '
      '/Subject (classic) /Keywords (fiction, ISBN 978-3-16-148410-0) '
      '/CreationDate (D:18651126090000+01\x2700\x27)>>',
    )
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << >> >>',
    )
    ..addObject(
      6,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 /Contents 8 0 R '
      '/Resources << >> >>',
    )
    ..addStreamObject(7, '', 'BT ET'.codeUnits)
    ..addStreamObject(8, '', 'BT ET'.codeUnits, flate: true)
    ..trailerExtra = ' /Info 3 0 R';
  if (withOutline) {
    fixture
      ..addObject(11, '<< /Type /Outlines /First 12 0 R /Last 13 0 R /Count 2 >>')
      ..addObject(
        12,
        '<< /Title (Chapter One) /Parent 11 0 R /Next 13 0 R /Dest [5 0 R /XYZ 0 792 null] >>',
      )
      ..addObject(13, '<< /Title (Chapter Two) /Parent 11 0 R /Dest [6 0 R /XYZ 0 792 null] >>');
  }

  return fixture;
}

/// A one-page fixture drawing one DCTDecode (JPEG passthrough) image
/// through an /XObject, so extraction and the session's on-demand
/// image path both see a drawable `images/pdf-image-<n>.jpg`.
PdfFixtureBuilder imagePageFixture(final List<int> jpegBytes) {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> /XObject << /Im0 8 0 R >> >> >>',
    )
    ..addStreamObject(
      7,
      '',
      'BT /F1 12 Tf 72 720 Td (A page with one drawn image) Tj ET\n'
              'q 200 0 0 150 72 500 cm /Im0 Do Q\n'
          .codeUnits,
    )
    ..addStreamObject(
      8,
      ' /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8'
      ' /Filter /DCTDecode',
      jpegBytes,
    )
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    );
}

/// A one-page fixture drawing one JPXDecode image through an /XObject,
/// mirroring [imagePageFixture]: extraction and the session's on-demand
/// image path both see a drawable `images/pdf-image-<n>.png`. [width]/
/// [height] must match the codestream's geometry (JPXDecode carries
/// its own authoritative dimensions); [components] selects the default
/// PDF family (DeviceGray/DeviceRGB), [ascii85] wraps the codestream
/// in an `/ASCII85Decode /JPXDecode` chain and [indirectColorSpace]
/// moves the colorspace to an indirect object. [bitsPerComponent] is
/// written as given (null omits the entry; the PDF specification makes
/// it optional and ignored for JPXDecode), [colorSpace] overrides the
/// family name and [drawTwice] places the image a second time so the
/// extraction dedup is observable.
PdfFixtureBuilder jpxImagePageFixture(
  final List<int> jpxBytes, {
  required final int width,
  required final int height,
  final int components = 1,
  final bool ascii85 = false,
  final bool indirectColorSpace = false,
  final int? bitsPerComponent = 8,
  final String? colorSpace,
  final bool drawTwice = false,
}) {
  final pdfColorSpace = colorSpace ?? (components == 3 ? 'DeviceRGB' : 'DeviceGray');
  final filter = ascii85 ? '[/ASCII85Decode /JPXDecode]' : '/JPXDecode';
  final colorspaceEntry = indirectColorSpace
      ? ' /ColorSpace 10 0 R'
      : ' /ColorSpace /$pdfColorSpace';
  final bitsEntry = bitsPerComponent == null ? '' : ' /BitsPerComponent $bitsPerComponent';
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> /XObject << /Im0 8 0 R >> >> >>',
    )
    ..addStreamObject(
      7,
      '',
      ('BT /F1 12 Tf 72 720 Td (A page with one drawn image) Tj ET\n'
              'q 200 0 0 150 72 500 cm /Im0 Do Q\n'
              '${drawTwice ? 'q 100 0 0 75 300 300 cm /Im0 Do Q\n' : ''}')
          .codeUnits,
    )
    ..addStreamObject(
      8,
      ' /Subtype /Image /Width $width /Height $height$bitsEntry'
      '$colorspaceEntry /Filter $filter',
      ascii85 ? ascii85Encode(jpxBytes) : jpxBytes,
    )
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    )
    ..addObject(10, indirectColorSpace ? '/$pdfColorSpace' : '<< /Type /Metadata /Subtype /XML >>');
}

/// Adobe-style ASCII85 (no whitespace, `<~` header omitted, `~>`
/// terminator), matching the reader's ASCII85Decode expectations.
Uint8List ascii85Encode(final List<int> bytes) {
  final out = BytesBuilder(copy: false);
  var index = 0;
  while (index < bytes.length) {
    final remaining = bytes.length - index;
    var value = 0;
    for (var i = 0; i < 4; i++) {
      value = (value << 8) | (index + i < bytes.length ? bytes[index + i] : 0);
    }
    final digits = List<int>.filled(5, 0);
    for (var i = 4; i >= 0; i--) {
      digits[i] = value % 85;
      value ~/= 85;
    }
    final emit = remaining == 1 ? 2 : (remaining == 2 ? 3 : (remaining == 3 ? 4 : 5));
    for (var i = 0; i < emit; i++) {
      out.add([digits[i] + 0x21]);
    }
    index += 4;
  }
  out.add([0x7E, 0x3E]); // ~>
  return out.toBytes();
}

const String _toUnicodeCMap =
    '/CIDInit /ProcSet findresource begin\n'
    '12 dict begin\n'
    'begincmap\n'
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n'
    '/CMapName /Adobe-Identity-UCS def\n'
    '/CMapType 2 def\n'
    '1 begincodespacerange\n'
    '<0000> <FFFF>\n'
    'endcodespacerange\n'
    '2 beginbfchar\n'
    '<0001> <0048>\n'
    '<0002> <0069>\n'
    'endbfchar\n'
    'endcmap\n'
    'CMapName currentdict /CMap defineresource pop\n'
    'end\n'
    'end';

const String _textContent =
    'BT /F1 12 Tf 72 720 Td (Hello world) Tj ET\n'
    'BT /F1 12 Tf 72 700 Td [(The) -40 (quick)] TJ ET\n'
    'BT /F1 12 Tf 72 680 Td 14 TL (First) Tj T* (Second) Tj ET\n'
    'BT /F1 12 Tf 72 650 Td (Left) Tj ET\n'
    'BT /F1 12 Tf 300 650 Td (Right) Tj ET\n'
    'BT /F2 12 Tf 72 600 Td <00010002> Tj ET\n';

/// A one-page fixture exercising the text extractor: a simple
/// Type1 font, a Type0/CID font with ToUnicode, Tj, TJ with kerning,
/// T* leading and the run-gap space join.
PdfFixtureBuilder textPageFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(3, '<</Title (Text Page)>>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R /F2 10 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _textContent.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 >>',
    )
    ..addObject(
      10,
      '<< /Type /Font /Subtype /Type0 /BaseFont /Test-Identity '
      '/Encoding /Identity-H /DescendantFonts [11 0 R] /ToUnicode 12 0 R >>',
    )
    ..addObject(
      11,
      '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Test-Identity '
      '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> '
      '/DW 500 >>',
    )
    ..addStreamObject(12, '', _toUnicodeCMap.codeUnits)
    ..trailerExtra = ' /Info 3 0 R';
}

const String _paragraphContent =
    'BT /F1 12 Tf 72 720 Td (It was the best of times, it was the worst of times, it was the age) Tj ET\n'
    'BT /F1 12 Tf 72 705 Td (of wisdom, it was the age of foolishness, it was the epoch of belief,) Tj ET\n'
    'BT /F1 12 Tf 72 690 Td (it was the epoch of incredulity, it was the season of Light,) Tj ET\n'
    'BT /F1 12 Tf 72 660 Td (A second paragraph starts here and runs along another line of) Tj ET\n'
    'BT /F1 12 Tf 72 645 Td (text that keeps the paragraph together through the unwrap rule.) Tj ET\n'
    'BT /F1 14 Tf 250 610 Td (CHAPTER I) Tj ET\n';

/// A one-page fixture with two coalescible paragraphs (same left,
/// line-space gaps) and a centered chapter heading.
PdfFixtureBuilder paragraphPageFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _paragraphContent.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 >>',
    );
}

/// A six-page fixture where every page repeats a running header and a
/// numbered footer around body text.
PdfFixtureBuilder headerFooterFixture() {
  final fixture = PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    );
  final kids = <String>[];
  for (var i = 0; i < 6; i++) {
    final page = 20 + i;
    final contents = 40 + i;
    kids.add('$page 0 R');
    fixture.addObject(
      page,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $contents 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    );
    final body = StringBuffer()
      ..write('BT /F1 12 Tf 72 755 Td (A Tale of Two Cities) Tj ET\n')
      ..write('BT /F1 12 Tf 72 700 Td (Body line one of page $i with plenty of width) Tj ET\n')
      ..write('BT /F1 12 Tf 72 685 Td (Body line two continues the same paragraph) Tj ET\n')
      ..write('BT /F1 12 Tf 72 670 Td (Body line three closes the paragraph fully.) Tj ET\n')
      ..write('BT /F1 12 Tf 250 60 Td (Page ${i + 1}) Tj ET\n');
    fixture.addStreamObject(contents, '', body.toString().codeUnits);
  }
  fixture.addObject(2, '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>');

  return fixture;
}

const String _standard14Content = 'BT /F1 12 Tf 72 720 Td (Hello) Tj ET\n';

/// A one-page fixture whose only font is a standard-14 Helvetica
/// carrying no `/Widths` array, so measurement must come from the
/// Adobe AFM metrics table.
PdfFixtureBuilder standardFontPageFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _standard14Content.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    );
}

/// A [pageCount]-page fixture with real body text on every page: a
/// shared standard-14 font, three flush-left body lines, a
/// distinctive searchable marker line per page and, with
/// [withHeaderFooter], a repeated running header and a numbered
/// footer — the shape the reflow's document-global passes sample.
PdfFixtureBuilder multipageTextFixture({
  final int pageCount = 6,
  final bool withHeaderFooter = false,
  final String marker = 'quixoticmarker',
}) {
  final fixture = PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(
      3,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    );
  const firstPageObject = 10;
  final kids = <String>[];
  for (var i = 0; i < pageCount; i++) {
    final page = firstPageObject + i * 2;
    final contents = page + 1;
    kids.add('$page 0 R');
    fixture.addObject(
      page,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $contents 0 R '
      '/Resources << /Font << /F1 3 0 R >> >> >>',
    );
    final body = StringBuffer();
    if (withHeaderFooter) {
      body.write('BT /F1 12 Tf 72 755 Td (A Tale of Two Cities) Tj ET\n');
    }
    body
      ..write('BT /F1 12 Tf 72 720 Td (Page $i opens with a plain body line of) Tj ET\n')
      ..write('BT /F1 12 Tf 72 705 Td (generous width so the paragraph coalescer has) Tj ET\n')
      ..write('BT /F1 12 Tf 72 690 Td (plenty to hold together across the line breaks.) Tj ET\n')
      ..write('BT /F1 12 Tf 72 660 Td (The $marker appears exactly once per page.) Tj ET\n');
    if (withHeaderFooter) {
      body.write('BT /F1 12 Tf 250 60 Td (Page ${i + 1}) Tj ET\n');
    }
    fixture.addStreamObject(contents, '', body.toString().codeUnits);
  }
  fixture.addObject(2, '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>');

  return fixture;
}

/// A [pageCount]-page fixture whose paragraphs run to the bottom of
/// every page and continue flush-left at the top of the next one —
/// the geometry the reflow's cross-page continuation pass fires on.
PdfFixtureBuilder continuationPagesFixture({final int pageCount = 5}) {
  final fixture = PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(
      3,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    );
  const firstPageObject = 10;
  final kids = <String>[];
  for (var i = 0; i < pageCount; i++) {
    final page = firstPageObject + i * 2;
    final contents = page + 1;
    kids.add('$page 0 R');
    fixture.addObject(
      page,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $contents 0 R '
      '/Resources << /Font << /F1 3 0 R >> >> >>',
    );
    final body = StringBuffer()
      ..write(
        'BT /F1 12 Tf 72 750 Td (the sentence carries over from the previous page and) Tj ET\n',
      )
      ..write('BT /F1 12 Tf 72 735 Td (runs onward through the whole column of this page) Tj ET\n')
      ..write('BT /F1 12 Tf 72 720 Td (until it nearly reaches the bottom margin of the) Tj ET\n')
      ..write('BT /F1 12 Tf 72 705 Td (page so the continuation pass has a real decision) Tj ET\n')
      ..write('BT /F1 12 Tf 72 690 Td (to make about the paragraph that follows it here) Tj ET\n')
      ..write('BT /F1 12 Tf 72 675 Td (and the paragraph that opens the next page fresh) Tj ET\n');
    fixture.addStreamObject(contents, '', body.toString().codeUnits);
  }
  fixture.addObject(2, '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>');

  return fixture;
}

const String _type0EmbeddedCMap =
    '/CIDInit /ProcSet findresource begin\n'
    '12 dict begin\n'
    'begincmap\n'
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> def\n'
    '/CMapName /Custom-Identity def\n'
    '/CMapType 1 def\n'
    '1 begincodespacerange\n'
    '<00> <FF>\n'
    'endcodespacerange\n'
    '1 begincidrange\n'
    '<41> <43> 500\n'
    'endcidrange\n'
    'endcmap\n'
    'CMapName currentdict /CMap defineresource pop\n'
    'end\n'
    'end';

const String _type0EmbeddedToUnicode =
    '/CIDInit /ProcSet findresource begin\n'
    '12 dict begin\n'
    'begincmap\n'
    '1 begincodespacerange\n'
    '<00> <FF>\n'
    'endcodespacerange\n'
    '3 beginbfchar\n'
    '<41> <0041>\n'
    '<42> <0042>\n'
    '<43> <0043>\n'
    'endbfchar\n'
    'endcmap\n'
    'CMapName currentdict /CMap defineresource pop\n'
    'end\n'
    'end';

const String _type0EmbeddedContent = 'BT /F1 12 Tf 72 720 Td <414243> Tj ET\n';

/// A one-page fixture with a Type0 font whose `/Encoding` is an
/// embedded one-byte CMap stream (`<41>-<43>` to CIDs 500-502) while
/// `/W` is keyed by CID (`600 700 800`, `/DW 500`) and ToUnicode
/// decodes the codes to `ABC`.
PdfFixtureBuilder type0CMapPageFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _type0EmbeddedContent.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type0 /BaseFont /Test-Embedded '
      '/Encoding 10 0 R /DescendantFonts [11 0 R] /ToUnicode 12 0 R >>',
    )
    ..addStreamObject(10, '', _type0EmbeddedCMap.codeUnits)
    ..addObject(
      11,
      '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Test-Embedded '
      '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> '
      '/DW 500 /W [500 502 [600 700 800]] >>',
    )
    ..addStreamObject(12, '', _type0EmbeddedToUnicode.codeUnits);
}

const String _columnContent =
    'BT /F1 12 Tf 72 750 Td (The Title of the Pamphlet) Tj ET\n'
    'BT /F1 12 Tf 72 60 Td (printed at the sign of the Dolphin) Tj ET\n'
    'BT /F1 12 Tf 72 700 Td (Left column opens the argument here with) Tj ET\n'
    'BT /F1 12 Tf 72 685 Td (several lines of body text to fill it out) Tj ET\n'
    'BT /F1 12 Tf 72 670 Td (and give the gutter detector real work to do) Tj ET\n'
    'BT /F1 12 Tf 72 655 Td (plus a shorter closing row) Tj ET\n'
    'BT /F1 12 Tf 340 700 Td (Right column answers the argument in turn) Tj ET\n'
    'BT /F1 12 Tf 340 685 Td (with its own body lines at the same height) Tj ET\n'
    'BT /F1 12 Tf 340 670 Td (so the two columns share rows and the) Tj ET\n'
    'BT /F1 12 Tf 340 655 Td (reading order must finish left before right) Tj ET\n';

/// A one-page fixture with a spanning title, a spanning footer and two
/// text columns separated by a wide empty gutter.
PdfFixtureBuilder columnPageFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _columnContent.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 >>',
    );
}

/// Draws a stroked hairline rectangle (a table rule) with a `re`
/// rectangle plus `S`.
// ignore: comment_references
String _rule(final double x, final double y, final double w, final double h) {
  return 'q 0.5 w $x $y ${w.toStringAsFixed(1)} ${h.toStringAsFixed(1)} re S Q\n';
}

final String _ruledTableContent =
    '${_rule(72, 600, 360, 100)}'
    '${_rule(72, 650, 360, 0)}'
    '${_rule(72, 600, 0, 100)}'
    '${_rule(192, 600, 0, 100)}'
    '${_rule(312, 600, 0, 100)}'
    '${_rule(432, 600, 0, 100)}'
    'BT /F1 12 Tf 82 675 Td (Alpha) Tj ET\n'
    'BT /F1 12 Tf 202 675 Td (Beta) Tj ET\n'
    'BT /F1 12 Tf 322 675 Td (Gamma) Tj ET\n'
    'BT /F1 12 Tf 82 625 Td (Delta) Tj ET\n'
    'BT /F1 12 Tf 202 625 Td (Epsilon) Tj ET\n'
    'BT /F1 12 Tf 322 625 Td (Zeta) Tj ET\n'
    'BT /F1 12 Tf 80 740 Td (Intro paragraph before the table for context.) Tj ET\n';

/// A one-page fixture with a complete 2x3 ruled lattice plus a plain
/// paragraph above it — the SpreadsheetExtractionAlgorithm shape.
PdfFixtureBuilder ruledTableFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _ruledTableContent.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 >>',
    );
}

const String _alignedTableContent =
    'BT /F1 12 Tf 72 700 Td (Name) Tj ET\n'
    'BT /F1 12 Tf 220 700 Td (Role) Tj ET\n'
    'BT /F1 12 Tf 360 700 Td (City) Tj ET\n'
    'BT /F1 12 Tf 72 680 Td (Ada) Tj ET\n'
    'BT /F1 12 Tf 220 680 Td (painter) Tj ET\n'
    'BT /F1 12 Tf 360 680 Td (Paris) Tj ET\n'
    'BT /F1 12 Tf 72 660 Td (Lou) Tj ET\n'
    'BT /F1 12 Tf 220 660 Td (sculptor) Tj ET\n'
    'BT /F1 12 Tf 360 660 Td (Lyon) Tj ET\n'
    'BT /F1 12 Tf 72 640 Td (Ren) Tj ET\n'
    'BT /F1 12 Tf 220 640 Td (critic) Tj ET\n'
    'BT /F1 12 Tf 360 640 Td (Nice) Tj ET\n'
    'BT /F1 12 Tf 72 600 Td (Prose paragraph underneath, ragged right, no grid.) Tj ET\n';

/// A one-page fixture whose upper block aligns three columns of words
/// across four rows with no ruling lines — the whitespace fallback.
PdfFixtureBuilder alignedTableFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _alignedTableContent.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 >>',
    );
}

const String _rotatedContent =
    'BT /F1 12 Tf 72 720 Td (Upright anchor line stays horizontal) Tj ET\n'
    'BT /F1 12 Tf 0 1 -1 0 500 720 Tm (Sideways) Tj ET\n';

/// A one-page fixture with a horizontal line and a 90-degree-rotated
/// word (the `Tm` matrix carries the rotation).
PdfFixtureBuilder rotatedTextFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _rotatedContent.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 >>',
    );
}

const String _ligatureCMap =
    '/CIDInit /ProcSet findresource begin\n'
    '12 dict begin\n'
    'begincmap\n'
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n'
    '/CMapType 2 def\n'
    '1 begincodespacerange\n'
    '<0000> <FFFF>\n'
    'endcodespacerange\n'
    '1 beginbfchar\n'
    '<0001> <006600660069>\n'
    'endbfchar\n'
    'endcmap\n'
    'CMapName currentdict /CMap defineresource pop\n'
    'end\n'
    'end';

const String _ligatureContent = 'BT /F2 12 Tf 72 720 Td <0001> Tj ET\n';

/// A one-page fixture where one CID code maps to the three characters
/// `ffi` (a ligature expansion through ToUnicode) at a single advance.
PdfFixtureBuilder ligatureWordFixture() {
  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
    ..addObject(
      5,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
      '/Resources << /Font << /F2 10 0 R >> >> >>',
    )
    ..addStreamObject(7, '', _ligatureContent.codeUnits)
    ..addObject(
      10,
      '<< /Type /Font /Subtype /Type0 /BaseFont /Lig-Identity '
      '/Encoding /Identity-H /DescendantFonts [11 0 R] /ToUnicode 12 0 R >>',
    )
    ..addObject(
      11,
      '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Lig-Identity '
      '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> '
      '/DW 500 >>',
    )
    ..addStreamObject(12, '', _ligatureCMap.codeUnits);
}

/// A [pageCount]-page fixture whose statistics change mid-document:
/// the first [plainPages] pages render in 12 pt Helvetica, the rest in
/// 10 pt — the eager plan sees both, the 20-page session sample sees
/// only the first kind.
PdfFixtureBuilder changingStatisticsFixture({final int pageCount = 26, final int plainPages = 20}) {
  final fixture = PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(
      3,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    );
  const firstPageObject = 10;
  final kids = <String>[];
  for (var i = 0; i < pageCount; i++) {
    final page = firstPageObject + i * 2;
    final contents = page + 1;
    kids.add('$page 0 R');
    fixture.addObject(
      page,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $contents 0 R '
      '/Resources << /Font << /F1 3 0 R >> >> >>',
    );
    final size = i < plainPages ? 12 : 10;
    final top = i < plainPages ? 720 : 730;
    final body = StringBuffer()
      ..write('BT /F1 $size Tf 72 $top Td (Chapter page $i opens with a plain) Tj ET\n')
      ..write('BT /F1 $size Tf 72 ${top - size + 3} Td (body line $i so statistics have) Tj ET\n')
      ..write(
        'BT /F1 $size Tf 72 ${top - 2 * (size - 3)} Td (real font clusters to find.) Tj ET\n',
      );
    fixture.addStreamObject(contents, '', body.toString().codeUnits);
  }
  fixture.addObject(2, '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>');

  return fixture;
}
