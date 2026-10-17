import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_decoder.dart';

void main(final List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final oracle = File(args[1]).readAsBytesSync();
  try {
    final image = decodeJpxImage(Uint8List.fromList(bytes));
    // The oracle payload is planar (component-major), matching
    // opj_decompress's .raw writer.
    final actual = <int>[];
    for (final plane in image.samples) {
      actual.addAll(plane);
    }
    if (args.length > 2 && args[2] == '--planes') {
      final perComp = image.width * image.height;
      for (var c = 0; c < image.componentCount; c++) {
        var matching = 0;
        for (var i = 0; i < perComp; i++) {
          if (oracle[c * perComp + i] == image.samples[c][i]) matching++;
        }
        // Dev probe diagnostics, not a test assertion: ignore the
        // print lint.
        // ignore: avoid_print
        print(
          'PLANE$c matching=$matching/${image.width}x${image.height} '
          'first12 mine: '
          '${[for (var i = 0; i < 12; i++) image.samples[c][i]].join(' ')} '
          'oracle: '
          '${[for (var i = 0; i < 12; i++) oracle[c * perComp + i]].join(' ')}',
        );
      }
      return;
    }
    stdout.writeln(
      'decoded ${image.width}x${image.height}x${image.componentCount} '
      '(${image.isJp2 ? 'jp2' : 'j2k'}), payload ${actual.length} bytes, '
      'oracle ${oracle.length} bytes',
    );
    if (actual.length != oracle.length) {
      stdout.writeln('SIZE MISMATCH');
      exitCode = 1;
      return;
    }
    for (var i = 0; i < 16; i++) {
      stdout.write('oracle ${oracle[i]}  actual ${actual[i]}  |  ');
      if (i % 2 == 1) stdout.writeln();
    }
    var maxErr = 0;
    var differing = 0;
    for (var index = 0; index < oracle.length; index++) {
      final delta = actual[index] - oracle[index];
      if (delta != 0) {
        differing++;
        if (delta.abs() > maxErr) {
          maxErr = delta.abs();
        }
        if (differing <= 20) {
          // Dev probe diagnostics: ignore the print lint.
          // ignore: avoid_print
          print(
            'MISMATCH index=$index x=${index % image.width} '
            'y=${index ~/ image.width} oracle=${oracle[index]} '
            'actual=${actual[index]}',
          );
        }
      }
    }
    stdout.writeln(
      differing == 0 ? 'EXACT MATCH' : 'DIFF: $differing samples differ, max |err| $maxErr',
    );
    if (differing != 0) {
      exitCode = 1;
    }
  } catch (error, stack) {
    stderr.writeln('DECODE FAILED: $error');
    stderr.writeln(stack);
    exitCode = 2;
  }
}
