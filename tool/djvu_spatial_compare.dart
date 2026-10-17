import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/src/features/djvu/djvu_text.dart';
import 'package:unseal/src/features/djvu/parse_djvu_book.dart';

/// Differential comparator between Unseal's DjVu spatial text and the
/// DjVuLibre reference dump.
///
/// Usage:
/// ```
/// dart run tool/djvu_spatial_compare.dart <book.djvu> <reference-dir> [--json <report.json>]
/// ```
///
/// `<reference-dir>` holds one `page-N.sexpr` per page (the output of
/// `djvused -e 'select N; print-txt'`, 1-based) and optionally
/// `page-N.txt` (`print-pure-txt`). The comparator walks both trees in
/// stored order and compares zone types, coordinates, and leaf texts;
/// the reference tools trim trailing whitespace when printing zone text
/// (the stored ranges include the separator bytes the next sibling
/// consumes), so the comparison trims both sides the same way. Page text
/// compares against `print-pure-txt` bytes after the documented NUL
/// rendering (stored NUL becomes LF + form feed) and trailing-newline
/// stripping.
///
/// Exit code 0 means every comparison matched; 1 reports the mismatches
/// and writes them to the JSON report when `--json` is given.
void main(final List<String> args) {
  final bookPath = args[0];
  final referenceDir = Directory(args[1]);
  final jsonIndex = args.indexOf('--json');
  final reportPath = jsonIndex >= 0 ? args[jsonIndex + 1] : null;

  final book = parseDjvuBook(File(bookPath).readAsBytesSync());
  final mismatches = <String>[];
  var pagesCompared = 0;
  var zonesCompared = 0;
  var leafTextsCompared = 0;
  var textPagesCompared = 0;

  for (var pageIndex = 0; pageIndex < book.pages.length; pageIndex++) {
    final sexprFile = File('${referenceDir.path}/page-${pageIndex + 1}.sexpr');
    if (!sexprFile.existsSync()) {
      mismatches.add('page ${pageIndex + 1}: missing reference dump');
      continue;
    }
    final oracle = _parseSexpr(sexprFile.readAsBytesSync());
    final chunk = book.pages[pageIndex].textChunk;
    pagesCompared++;
    if (oracle == null) {
      mismatches.add('page ${pageIndex + 1}: reference dump holds no s-expression');
      continue;
    }
    final oracleHasZones = oracle.children.isNotEmpty;
    final oracleHasText = (oracle.text ?? '').isNotEmpty;
    if (chunk == null) {
      if (oracleHasZones || oracleHasText) {
        mismatches.add('page ${pageIndex + 1}: Unseal has no text chunk, reference has one');
      }
      continue;
    }
    final unsealHasZones = chunk.root != null;
    if (unsealHasZones && !oracleHasZones) {
      mismatches.add('page ${pageIndex + 1}: Unseal decoded zones, reference has none');
      continue;
    }
    if (!unsealHasZones && oracleHasZones) {
      mismatches.add('page ${pageIndex + 1}: Unseal decoded no zones, reference has some');
      continue;
    }
    if (unsealHasZones) {
      _compareZone(
        oracle,
        chunk.root!,
        chunk,
        'page ${pageIndex + 1}',
        mismatches,
        () => zonesCompared++,
        () => leafTextsCompared++,
      );
    }

    final pureFile = File('${referenceDir.path}/page-${pageIndex + 1}.txt');
    if (pureFile.existsSync()) {
      final stored = pureFile.readAsStringSync();
      // print-pure-txt emits the stored text followed by the form-feed
      // page separator; strip that one separator before rendering.
      final trimmed = stored.endsWith('\x0C') ? stored.substring(0, stored.length - 1) : stored;
      final rendered = trimmed.replaceAll('\x00', '\n\x0C');
      if (rendered != chunk.text) {
        mismatches.add(
          'page ${pageIndex + 1}: page text differs '
          '(unseal ${chunk.text.length} units, reference ${rendered.length} units)',
        );
      } else {
        textPagesCompared++;
      }
    }
  }

  final verdict = mismatches.isEmpty ? 'pass' : 'fail';
  final report = <String, Object?>{
    'tool': 'djvu_spatial_compare',
    'book': bookPath,
    'pagesCompared': pagesCompared,
    'textPagesCompared': textPagesCompared,
    'zoneRecordsCompared': zonesCompared,
    'leafTextsCompared': leafTextsCompared,
    'mismatches': mismatches,
    'verdict': verdict,
  };
  if (reportPath != null) {
    File(reportPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  }
  if (mismatches.isNotEmpty) {
    for (final mismatch in mismatches.take(20)) {
      stderr.writeln(mismatch);
    }
    stderr.writeln('$verdict: ${mismatches.length} mismatches');
    exitCode = 1;
  } else {
    stdout.writeln(
      'pass: $pagesCompared pages, $zonesCompared zone records, '
      '$leafTextsCompared leaf texts, $textPagesCompared page texts',
    );
  }
}

String _trimTrailingWhitespace(final String text) {
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) <= 0x20) {
    end--;
  }

  return text.substring(0, end);
}

String _escape(final String s) => s.codeUnits
    .map((final u) => u < 0x20 || u > 0x7e ? '<0x${u.toRadixString(16)}>' : String.fromCharCode(u))
    .join('');

void _compareZone(
  final _ReferenceZone oracle,
  final DjvuTextZone zone,
  final DjvuTextChunk chunk,
  final String where,
  final List<String> mismatches,
  final void Function() countZone,
  final void Function() countLeaf,
) {
  countZone();
  const kinds = <String, int>{
    'page': djvuZoneTypePage,
    'column': djvuZoneTypeColumn,
    'region': djvuZoneTypeRegion,
    'para': djvuZoneTypeParagraph,
    'line': djvuZoneTypeLine,
    'word': djvuZoneTypeWord,
    'character': djvuZoneTypeCharacter,
  };
  if (kinds[oracle.kind] != zone.type) {
    mismatches.add('$where: kind ${oracle.kind} != type ${zone.type}');
  }
  if (oracle.coords.length >= 4) {
    final matches = oracle.coords[0] == zone.xmin &&
        oracle.coords[1] == zone.ymin &&
        oracle.coords[2] == zone.xmax &&
        oracle.coords[3] == zone.ymax;
    if (!matches) {
      mismatches.add(
        '$where ${oracle.kind}: coords (${oracle.coords.join(' ')}) '
        '!= (${zone.xmin} ${zone.ymin} ${zone.xmax} ${zone.ymax})',
      );
    }
  }
  if (oracle.children.length != zone.children.length) {
    mismatches.add(
      '$where ${oracle.kind}: ${zone.children.length} children != ${oracle.children.length}',
    );
  }
  if (oracle.text != null) {
    countLeaf();
    final expected = oracle.text!;
    final actual = chunk.text.substring(zone.utf16Start, zone.utf16End);
    if (_trimTrailingWhitespace(actual) != _trimTrailingWhitespace(expected)) {
      mismatches.add(
        '$where ${oracle.kind}: text ${_escape(actual)} != ${_escape(expected)}',
      );
    }
  }
  final limit = zone.children.length < oracle.children.length
      ? zone.children.length
      : oracle.children.length;
  for (var i = 0; i < limit; i++) {
    _compareZone(
      oracle.children[i],
      zone.children[i],
      chunk,
      '$where/${oracle.kind}[$i]',
      mismatches,
      countZone,
      countLeaf,
    );
  }
}

/// One s-expression node from the reference dump: its kind, the numeric
/// atoms in stored order (xmin ymin xmax ymax), the optional quoted text,
/// and the child zones.
class _ReferenceZone {
  _ReferenceZone(this.kind);

  final String kind;
  final List<int> coords = <int>[];
  final List<_ReferenceZone> children = <_ReferenceZone>[];
  String? text;
}

/// Parses the first s-expression of [source]; `djvused print-txt` emits
/// exactly one per page.
_ReferenceZone? _parseSexpr(final List<int> source) {
  _ReferenceZone? root;
  final stack = <_ReferenceZone>[];
  var position = 0;
  while (position < source.length) {
    final char = source[position];
    switch (char) {
      case 0x20 || 0x0A || 0x09 || 0x0D:
        position++;
      case 0x28:
        position++;
        var kindEnd = position;
        while (kindEnd < source.length &&
            source[kindEnd] != 0x20 &&
            source[kindEnd] != 0x28 &&
            source[kindEnd] != 0x29) {
          kindEnd++;
        }
        final node = _ReferenceZone(ascii.decode(source.sublist(position, kindEnd)));
        position = kindEnd;
        if (stack.isEmpty) {
          root = node;
        } else {
          stack.last.children.add(node);
        }
        stack.add(node);
      case 0x29:
        position++;
        if (stack.isNotEmpty) stack.removeLast();
      case 0x22:
        position++;
        final buffer = BytesBuilder();
        while (position < source.length && source[position] != 0x22) {
          if (source[position] == 0x5C && position + 1 < source.length) {
            position++;
            if (source[position] >= 0x30 && source[position] <= 0x37) {
              // djvused escapes non-ASCII bytes as backslash-octal.
              var value = 0;
              var digits = 0;
              while (digits < 3 &&
                  position < source.length &&
                  source[position] >= 0x30 &&
                  source[position] <= 0x37) {
                value = value * 8 + (source[position] - 0x30);
                digits++;
                position++;
              }
              buffer.addByte(value);
              continue;
            }
          }
          buffer.addByte(source[position]);
          position++;
        }
        position++;
        if (stack.isNotEmpty && stack.last.text == null) {
          stack.last.text = utf8.decode(buffer.toBytes(), allowMalformed: false);
        }
      default:
        if ((char >= 0x30 && char <= 0x39) || char == 0x2D) {
          final start = position;
          if (char == 0x2D) position++;
          while (position < source.length && source[position] >= 0x30 && source[position] <= 0x39) {
            position++;
          }
          if (stack.isNotEmpty) {
            stack.last.coords.add(int.parse(ascii.decode(source.sublist(start, position))));
          }
        } else {
          position++;
        }
    }
  }

  return root;
}
