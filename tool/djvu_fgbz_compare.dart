// D04 FGbz comparator: runs the three lossless comparison lanes of
// doc/djvu-fgbz.md against the native DjVuLibre oracle.
//
// Lane 1 diffs the native blit list, FGbz palette, and per-blit color
// indices (extracted by tool/djvu_fgbz_oracle.cpp) against the Dart decoders.
// Lane 2 rebuilds the native foreground raster — white paper, every ink
// pixel in its blit's palette color, black ink without FGbz — and requires
// byte identity with `ddjvu -mode=foreground -format=ppm` output. Lane 3
// records the composed page-image hashes the Unseal parser produces.
//
// Usage:
//   dart run tool/djvu_fgbz_compare.dart <file.djvu> <oracle.json> \
//       <ppm-dir> [--out <report.json>]
//
// <ppm-dir> holds one `<basename>-p<page>-foreground.ppm` per compared page
// (pages without a raster file are compared on lane 1 only). Exit 0 means
// every compared lane matched; 1 is a comparison failure; 2 is usage error.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/src/features/djvu/bzz_decoder.dart';
import 'package:unseal/src/features/djvu/djvu_layer_compositor.dart';
import 'package:unseal/src/features/djvu/fgbz_decoder.dart';
import 'package:unseal/src/features/djvu/jb2_decoder.dart';
import 'package:unseal/src/features/djvu/parse_djvu_book.dart';

void main(final List<String> arguments) {
  final file = arguments.length >= 3 ? arguments[0] : null;
  final oraclePath = arguments.length >= 3 ? arguments[1] : null;
  final ppmDir = arguments.length >= 3 ? arguments[2] : null;
  if (file == null || oraclePath == null || ppmDir == null) {
    stderr.writeln(
      'usage: dart run tool/djvu_fgbz_compare.dart <file.djvu> <oracle.json> <ppm-dir> [--out report.json]',
    );
    exit(2);
  }
  var outPath = '';
  for (var i = 3; i < arguments.length - 1; i++) {
    if (arguments[i] == '--out') outPath = arguments[i + 1];
  }

  final bytes = File(file).readAsBytesSync();
  final oracle = jsonDecode(File(oraclePath).readAsStringSync()) as Map<String, Object?>;
  final oraclePages = (oracle['pages'] as List<Object?>).cast<Map<String, Object?>>();

  if (oraclePages.isEmpty) throw StateError('Reference contains no pages');
  final document = _DjvuWalk(bytes);
  final book = parseDjvuBook(bytes);
  final failures = <String>[];
  final pageReports = <Object?>[];
  if (oraclePages.length != book.pageCount) {
    throw StateError('Reference page count does not match the public book');
  }
  final observed = <int>{};
  for (final oraclePage in oraclePages) {
    final pageNumber = oraclePage['page'] as int;
    if (!observed.add(pageNumber) || pageNumber < 1 || pageNumber > book.pageCount) {
      throw StateError('Invalid or duplicate reference page');
    }
    final report = <String, Object?>{'page': pageNumber};
    pageReports.add(report);
    final page = document.page(pageNumber);
    if (page == null) {
      failures.add('page $pageNumber: absent from the file walk');
      continue;
    }

    // ---- Lane 1: blits, palette, indices ---------------------------------
    final sjbz = page.sjbz;
    final info = page.info;
    if (sjbz == null || info == null) {
      failures.add('page $pageNumber: missing Sjbz or INFO');
      continue;
    }
    final oracleSjbz = oraclePage['sjbz'] as Map<String, Object?>?;
    final oracleFgbz = oraclePage['fgbz'] as Map<String, Object?>?;
    final nativeFg44 = oraclePage['fg44Foreground'] as bool? ?? false;
    if (page.fgbz != null && nativeFg44) {
      failures.add('page $pageNumber: FGbz and FG44 foreground coexist in the native view');
      continue;
    }

    DjvuFgbzPalette? palette;
    if (page.fgbz != null) {
      palette = decodeDjvuFgbz(page.fgbz!);
      if (oracleFgbz == null) {
        failures.add('page $pageNumber: Dart decoded FGbz the oracle does not carry');
        continue;
      }
      final oraclePalette = (oracleFgbz['palette'] as List<Object?>).cast<List<Object?>>();
      if (oraclePalette.length * 3 != palette.rgb.length) {
        failures.add(
          'page $pageNumber: palette size ${palette.rgb.length ~/ 3}'
          ' differs from native ${oraclePalette.length}',
        );
        continue;
      }
      for (var entry = 0; entry < oraclePalette.length; entry++) {
        final nativeR = oraclePalette[entry][0] as int;
        final nativeG = oraclePalette[entry][1] as int;
        final nativeB = oraclePalette[entry][2] as int;
        final ours = (
          palette.rgb[entry * 3],
          palette.rgb[entry * 3 + 1],
          palette.rgb[entry * 3 + 2],
        );
        if (ours != (nativeR, nativeG, nativeB)) {
          failures.add(
            'page $pageNumber: palette entry $entry ours $ours vs native'
            ' ($nativeR, $nativeG, $nativeB)',
          );
        }
      }
      final oracleIndices = oracleFgbz['colordata'] as List<Object?>;
      final dartIndices = palette.colorIndices ?? const <int>[];
      if (palette.hasColorData && dartIndices.length != oracleIndices.length) {
        failures.add(
          'page $pageNumber: ${dartIndices.length} color indices vs native ${oracleIndices.length}',
        );
      } else if (palette.hasColorData) {
        for (var i = 0; i < dartIndices.length; i++) {
          if (dartIndices[i] != oracleIndices[i]) {
            failures.add(
              'page $pageNumber: color index $i is ${dartIndices[i]} vs native ${oracleIndices[i]}',
            );
            break;
          }
        }
      }
      report['paletteSize'] = palette.rgb.length ~/ 3;
      report['colorIndices'] = dartIndices.length;
    } else if (oracleFgbz != null) {
      failures.add('page $pageNumber: the oracle decodes FGbz, the Dart walk found none');
      continue;
    }

    if (oracleSjbz != null) {
      DjvuJb2SharedDictionary? inherited;
      final dictTarget = page.inclTargets.isEmpty ? page.inlineDjbzId : page.inclTargets.first;
      final djbz = dictTarget == null ? null : document.sharedDictionary(dictTarget);
      if (djbz != null) {
        inherited = decodeDjvuJb2Dictionary(djbz, ledger: DjvuSharedDictionaryLedger());
      }
      final decoded = decodeDjvuJb2Page(
        sjbz,
        expectedWidth: info.width,
        expectedHeight: info.height,
        inherited: inherited,
        collectBlits: true,
      );
      final blits = decoded.blits!;
      final nativeBlits = (oracleSjbz['blits'] as List<Object?>).cast<Map<String, Object?>>();
      if (blits.length != nativeBlits.length) {
        failures.add('page $pageNumber: ${blits.length} blits vs native ${nativeBlits.length}');
      } else {
        for (var i = 0; i < blits.length; i++) {
          final native = nativeBlits[i];
          final ours = blits[i];
          final same =
              ours.left == native['left'] &&
              ours.bottom == native['bottom'] &&
              ours.shapeNumber == native['shape'] &&
              ours.symbol.width == native['w'] &&
              ours.symbol.height == native['h'] &&
              _packedSymbol(ours.symbol) == native['bits'];
          if (!same) {
            failures.add(
              'page $pageNumber: blit $i ours (left ${ours.left}, bottom ${ours.bottom},'
              ' ${ours.symbol.width}x${ours.symbol.height}) vs native'
              ' (${native['left']}, ${native['bottom']}, ${native['w']}x${native['h']})',
            );
            break;
          }
        }
      }
      report['blits'] = blits.length;
    }

    // ---- Lane 2: native foreground raster --------------------------------
    final baseName = File(file).uri.pathSegments.last.replaceAll(RegExp(r'\.djvu$'), '');
    final ppm = File('$ppmDir/$baseName-p$pageNumber-foreground.ppm');
    if (ppm.existsSync()) {
      final raster = _decodePpm(ppm.readAsBytesSync());
      final foreground = _renderForeground(document, page, palette);
      if (raster.width != foreground.width || raster.height != foreground.height) {
        failures.add(
          'page $pageNumber: foreground ${foreground.width}x${foreground.height}'
          ' vs native ${raster.width}x${raster.height}',
        );
      } else if (!_sameBytes(raster.rgb, foreground.rgb)) {
        var firstDifference = -1;
        for (var i = 0; i < raster.rgb.length; i++) {
          if (raster.rgb[i] != foreground.rgb[i]) {
            firstDifference = i;
            break;
          }
        }
        failures.add(
          'page $pageNumber: foreground raster differs from the native PPM'
          ' (first differing byte $firstDifference)',
        );
      }
      report['foregroundRaster'] = 'compared';
    } else {
      if (oracleFgbz != null || pageNumber == 1) {
        failures.add('page $pageNumber: required native foreground raster missing');
      }
      report['foregroundRaster'] = 'outside colored foreground lane: no FGbz';
    }

    // ---- Lane 3: composed page image hash --------------------------------
    report['imageSha256'] = _sha256(book.pages[pageNumber - 1].image.content);
  }

  final reportJson = <String, Object?>{
    'file': file,
    'oracle': oraclePath,
    'lanes': {'blits': 1, 'paletteIndices': 1, 'foreground': 2, 'composite': 3},
    'pages': pageReports,
    'failures': failures,
    'pass': failures.isEmpty,
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(reportJson);
  if (outPath.isNotEmpty) {
    File(outPath).writeAsStringSync('$encoded\n');
  }
  stdout.writeln(encoded);
  exit(failures.isEmpty ? 0 : 1);
}

({int width, int height, Uint8List rgb}) _renderForeground(
  final _DjvuWalk document,
  final _WalkedPage page,
  final DjvuFgbzPalette? palette,
) {
  final info = page.info!;
  DjvuJb2SharedDictionary? inherited;
  final dictTarget = page.inclTargets.isEmpty ? page.inlineDjbzId : page.inclTargets.first;
  final djbz = dictTarget == null ? null : document.sharedDictionary(dictTarget);
  if (djbz != null) {
    inherited = decodeDjvuJb2Dictionary(djbz, ledger: DjvuSharedDictionaryLedger());
  }
  if (palette != null && palette.hasColorData) {
    final colorized = decodeDjvuJb2ColorizedMask(
      page.sjbz!,
      expectedWidth: info.width,
      expectedHeight: info.height,
      inherited: inherited,
      colors: palette,
    );
    return _decodeBmp(encodeDjvuColoredMaskBmp(colorized));
  }
  final mask = decodeDjvuJb2Mask(
    page.sjbz!,
    expectedWidth: info.width,
    expectedHeight: info.height,
    inherited: inherited,
  );
  return _decodeBmp(encodeDjvuJb2Bmp(mask));
}

({int width, int height, Uint8List rgb}) _decodePpm(final Uint8List bytes) {
  // P6 header: magic, whitespace, width, whitespace, height, whitespace,
  // maxval, exactly one whitespace byte, then RGB samples.
  bool isSpace(final int byte) => byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D;
  var position = 0;
  int token() {
    while (position < bytes.length && isSpace(bytes[position])) {
      position++;
    }
    final start = position;
    while (position < bytes.length && !isSpace(bytes[position])) {
      position++;
    }
    return int.parse(String.fromCharCodes(bytes, start, position));
  }

  if (String.fromCharCodes(bytes, 0, 2) != 'P6') {
    throw const FormatException('not a P6 PPM');
  }
  position += 2;
  final width = token();
  final height = token();
  final maxval = token();
  position++; // the single whitespace byte after maxval
  if (maxval != 255) {
    throw const FormatException('unexpected PPM maxval');
  }
  return (
    width: width,
    height: height,
    rgb: Uint8List.sublistView(bytes, position, position + width * height * 3),
  );
}

({int width, int height, Uint8List rgb}) _decodeBmp(final Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final offset = view.getUint32(10, Endian.little);
  final width = view.getInt32(18, Endian.little);
  final height = view.getInt32(22, Endian.little);
  final planes = view.getUint16(26, Endian.little);
  final bpp = view.getUint16(28, Endian.little);
  if (planes != 1 || (bpp != 24 && bpp != 1)) {
    throw const FormatException('unsupported BMP layout');
  }
  final stride = bpp == 24 ? (width * 3 + 3) & ~3 : ((width + 31) ~/ 32) * 4;
  final rgb = Uint8List(width * height * 3);
  if (bpp == 1) {
    // The 1-bit mask BMP: two BGRA palette entries after the headers; a
    // zero bit is ink (entry 0, black) and a set bit is paper (entry 1).
    for (var y = 0; y < height; y++) {
      final source = offset + (height - 1 - y) * stride;
      final target = y * width * 3;
      for (var x = 0; x < width; x++) {
        final bit = (bytes[source + x ~/ 8] >> (7 - (x & 7))) & 1;
        final level = bit == 0 ? 0 : 255;
        rgb[target + x * 3] = level;
        rgb[target + x * 3 + 1] = level;
        rgb[target + x * 3 + 2] = level;
      }
    }
    return (width: width, height: height, rgb: rgb);
  }
  for (var y = 0; y < height; y++) {
    final source = offset + (height - 1 - y) * stride;
    final target = y * width * 3;
    for (var x = 0; x < width; x++) {
      rgb[target + x * 3] = bytes[source + x * 3 + 2];
      rgb[target + x * 3 + 1] = bytes[source + x * 3 + 1];
      rgb[target + x * 3 + 2] = bytes[source + x * 3];
    }
  }
  return (width: width, height: height, rgb: rgb);
}

String _packedSymbol(final DjvuJb2Symbol symbol) {
  final hex = StringBuffer();
  for (var y = 0; y < symbol.height; y++) {
    for (var x = 0; x < symbol.width; x += 8) {
      var packed = 0;
      for (var bit = 0; bit < 8 && x + bit < symbol.width; bit++) {
        if (symbol.pixels[y * symbol.width + x + bit] != 0) packed |= 0x80 >> bit;
      }
      hex.write(packed.toRadixString(16).padLeft(2, '0'));
    }
  }
  return hex.toString();
}

bool _sameBytes(final Uint8List a, final Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _sha256(final List<int> bytes) {
  // Minimal SHA-256 to avoid a package dependency in the tool.
  final length = bytes.length;
  final withPadding = length + 9;
  final total = (withPadding + 63) & ~63;
  final message = Uint8List(total);
  message.setRange(0, length, bytes);
  message[length] = 0x80;
  final view = ByteData.sublistView(message);
  view.setUint64(total - 8, length * 8);
  const k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  final w = List<int>.filled(64, 0);
  for (var block = 0; block < total; block += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = view.getUint32(block + t * 4);
    }
    for (var t = 16; t < 64; t++) {
      final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
      final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final temp1 = (h + s1 + ch + k[t] + w[t]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }
  final digest = ByteData(32);
  digest.setUint32(0, h0);
  digest.setUint32(4, h1);
  digest.setUint32(8, h2);
  digest.setUint32(12, h3);
  digest.setUint32(16, h4);
  digest.setUint32(20, h5);
  digest.setUint32(24, h6);
  digest.setUint32(28, h7);
  return digest.buffer.asUint8List().map((final b) => b.toRadixString(16).padLeft(2, '0')).join();
}

int _rotr(final int value, final int bits) =>
    ((value >>> bits) | (value << (32 - bits))) & 0xFFFFFFFF;

/// A structural IFF walk over one DjVu file, exposing the chunks the
/// comparison needs. It mirrors the parser's bundled-walk rules without
/// sharing its code, so a walk divergence shows up as a comparison failure.
final class _DjvuWalk {
  _DjvuWalk(this.bytes) : view = ByteData.sublistView(bytes) {
    if (bytes.length < 16 || String.fromCharCodes(bytes, 0, 4) != 'AT&T') {
      throw const FormatException('not a DjVu file');
    }
    final root = _chunkAt(4);
    final form = String.fromCharCodes(bytes, root.$2, root.$2 + 4);
    if (form == 'DJVU') {
      _pages.add(_walkPage(root.$2 + 4, root.$3));
    } else if (form == 'DJVM') {
      _walkBundled(root.$2, root.$3);
    } else {
      throw FormatException('unsupported root FORM $form');
    }
  }

  final Uint8List bytes;
  final ByteData view;
  final List<_WalkedPage> _pages = [];
  final Map<String, Uint8List> _dictionaries = {};

  _WalkedPage? page(final int number) =>
      number >= 1 && number <= _pages.length ? _pages[number - 1] : null;

  Uint8List? sharedDictionary(final String id) => _dictionaries[id];

  (String, int, int) _chunkAt(final int offset) {
    final id = String.fromCharCodes(bytes, offset, offset + 4);
    final length = view.getUint32(offset + 4);
    final data = offset + 8;
    return (id, data, data + length);
  }

  void _walkBundled(final int dataStart, final int end) {
    final entries = _children(dataStart + 4, end);
    final dirm = entries.first;
    if (dirm.id != 'DIRM') throw const FormatException('missing DIRM');
    final flags = bytes[dirm.data];
    if (flags & 0x80 == 0) throw const FormatException('indirect bundle');
    final count = view.getUint16(dirm.data + 1);
    final offsets = <int>[for (var i = 0; i < count; i++) view.getUint32(dirm.data + 3 + i * 4)];
    final names = decodeDjvuBzz(
      Uint8List.sublistView(bytes, dirm.data + 3 + count * 4, dirm.end),
      truncatedMessage: 'truncated DIRM names',
    );
    var position = count * 3;
    final componentFlags = <int>[for (var i = 0; i < count; i++) names[position++]];
    final ids = <String>[];
    for (var i = 0; i < count; i++) {
      final nameEnd = names.indexOf(0, position);
      ids.add(String.fromCharCodes(names, position, nameEnd));
      position = nameEnd + 1;
      if (componentFlags[i] & 0x80 != 0) position = names.indexOf(0, position) + 1;
      if (componentFlags[i] & 0x40 != 0) position = names.indexOf(0, position) + 1;
    }
    final components = <int, (int, int)>{};
    for (final entry in entries.skip(1)) {
      if (entry.id == 'FORM') {
        components[entry.start] = (entry.data, entry.end);
      }
    }
    for (var i = 0; i < count; i++) {
      final component = components[offsets[i]];
      if (component == null) continue;
      final type = String.fromCharCodes(bytes, component.$1, component.$1 + 4);
      if (type == 'DJVU') {
        _pages.add(_walkPage(component.$1 + 4, component.$2));
      } else if (type == 'DJVI') {
        for (final chunk in _children(component.$1 + 4, component.$2)) {
          if (chunk.id == 'Djbz') {
            _dictionaries[ids[i]] = Uint8List.sublistView(bytes, chunk.data, chunk.end);
          }
        }
      }
    }
  }

  _WalkedPage _walkPage(final int childStart, final int end) {
    final page = _WalkedPage();
    for (final chunk in _children(childStart, end)) {
      switch (chunk.id) {
        case 'INFO':
          page.info = (width: view.getUint16(chunk.data), height: view.getUint16(chunk.data + 2));
        case 'Sjbz':
          page.sjbz = Uint8List.sublistView(bytes, chunk.data, chunk.end);
        case 'FGbz':
          page.fgbz = Uint8List.sublistView(bytes, chunk.data, chunk.end);
        case 'INCL':
          page.inclTargets.add(String.fromCharCodes(bytes, chunk.data, chunk.end));
        case 'Djbz':
          page.inlineDjbzId = '#inline#${chunk.data}';
          _dictionaries[page.inlineDjbzId!] = Uint8List.sublistView(bytes, chunk.data, chunk.end);
      }
    }
    return page;
  }

  List<({String id, int start, int data, int end})> _children(final int start, final int end) {
    final result = <({String id, int start, int data, int end})>[];
    var offset = start;
    while (offset < end) {
      final (id, data, chunkEnd) = _chunkAt(offset);
      result.add((id: id, start: offset, data: data, end: chunkEnd));
      // IFF pads odd chunks to even lengths; a final chunk needs no pad.
      offset = chunkEnd == end ? end : chunkEnd + ((chunkEnd - data) & 1);
    }
    return result;
  }
}

class _WalkedPage {
  ({int width, int height})? info;
  Uint8List? sjbz;
  Uint8List? fgbz;
  final List<String> inclTargets = [];
  String? inlineDjbzId;
}
