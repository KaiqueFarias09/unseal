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
        out.add('<< /Length ${data.length}$_streamEntries[number]$filter >>\n'.codeUnits);
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
        out.add('<< /Length ${data.length}$_streamEntries[number]$filter >>\n'.codeUnits);
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
      '/Creator (fixture writer) /Producer (eLivre tests) '
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
