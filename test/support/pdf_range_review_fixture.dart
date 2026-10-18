import 'dart:convert';
import 'dart:typed_data';

/// A PDF whose last two content streams are outside every structural window.
Uint8List spacedPdfRangeFixture({final bool indirectFilter = false}) {
  final objects = <int, List<int>>{};
  List<int> text(final String value) => latin1.encode(value);
  if (indirectFilter) {
    objects[1] = text('<< /Type /Catalog /Pages 2 0 R >>');
    objects[2] = text('<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
    objects[3] = text(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    );
    objects[4] = text('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
    final content = text('BT /F1 12 Tf 72 720 Td (Hello indirect filter) Tj ET');
    objects[5] = text(
      '<< /Length ${content.length * 2 + 1} /Filter 6 0 R >>\nstream\n'
      '${content.map((final byte) => byte.toRadixString(16).padLeft(2, '0')).join()}>\nendstream',
    );
    objects[6] = text('/ASCIIHexDecode');
  } else {
    objects[1] = text('<< /Type /Catalog /Pages 2 0 R >>');
    objects[2] = text(
      '<< /Type /Pages /Count 22 /Kids ['
      '${[for (var page = 0; page < 22; page++) '${4 + page} 0 R'].join(' ')}] >>',
    );
    objects[3] = text('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
    for (var page = 0; page < 22; page++) {
      objects[4 + page] = text(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents ${26 + page} 0 R >>',
      );
    }
    for (var page = 0; page < 22; page++) {
      final content = 'BT /F1 12 Tf 72 720 Td (Content page ${String.fromCharCode(65 + page)}) Tj ET';
      objects[26 + page] = text('<< /Length ${content.length} >>\nstream\n$content\nendstream');
    }
  }
  final output = BytesBuilder()..add(text('%PDF-1.4\n'));
  final offsets = <int>[0];
  final padding = Uint8List(128 << 10)..fillRange(0, 128 << 10, 32);
  for (final entry in objects.entries) {
    if ((indirectFilter && entry.key == 6) || (!indirectFilter && entry.key >= 46)) {
      output.add(padding);
    }
    offsets.add(output.length);
    output.add(text('${entry.key} 0 obj\n'));
    output.add(entry.value);
    output.add(text('\nendobj\n'));
  }
  output.add(padding);
  final xref = output.length;
  output.add(text('xref\n0 ${offsets.length}\n0000000000 65535 f \n'));
  for (final offset in offsets.skip(1)) {
    output.add(text('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  output.add(
    text(
      'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    ),
  );
  return output.toBytes();
}
