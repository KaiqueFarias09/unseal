import 'dart:typed_data';

import 'package:e_livre/features/core/entities/file/binary_file.dart';
import 'package:e_livre/features/core/entities/navigation/nav_point.dart';
import 'package:e_livre/features/core/entities/navigation/navigation.dart';
import 'package:e_livre/features/core/utils/image_sniffer.dart';
import 'package:e_livre/features/mobi/utils/fonts.dart';

/// Inserts `<a id="fileposN">` anchors at the target positions of
/// `filepos` links, operating on raw markup bytes so positions keep
/// their byte semantics.
Uint8List addFileposAnchors(final Uint8List html) {
  final positions = <int>{};
  final marker = _asciiPattern('filepos=');
  var searchFrom = 0;
  while (true) {
    final at = _indexOfPattern(html, marker, searchFrom, caseInsensitive: true);
    if (at == -1) break;
    searchFrom = at + marker.length;

    // Skip optional quote, then read the decimal value.
    var i = at + marker.length;
    if (i < html.length && (html[i] == 0x27 || html[i] == 0x22)) i++;
    var value = 0;
    var digits = 0;
    while (i < html.length && html[i] >= 0x30 && html[i] <= 0x39) {
      value = value * 10 + (html[i] - 0x30);
      i++;
      digits++;
    }
    if (digits > 0) {
      positions.add(value);
    }
  }

  final out = BytesBuilder(copy: false);
  var pos = 0;
  for (final oend in positions.toList()..sort()) {
    if (oend == 0 || oend >= html.length) {
      continue;
    }
    var end = oend;
    final lt = _indexOfByte(html, 0x3C, end);
    final gt = _indexOfByte(html, 0x3E, end);
    var anchor = '<a id="filepos$oend"></a>';
    if (gt > -1 && (gt < lt || lt == end || lt == -1)) {
      final p = _lastIndexOfByte(html, 0x3C, 0, end + 1);
      final isEndTag = p > -1 && p + 1 < html.length && html[p + 1] == 0x2F;
      final selfClosed =
          p > -1 && gt > p && html[gt - 1] == 0x2F; // '.../>'
      if (pos < end && p > -1 && !isEndTag && !selfClosed) {
        anchor = ' filepos-id="filepos$oend"';
        end = gt;
      } else {
        end = gt + 1;
      }
    }
    if (end <= pos) {
      continue;
    }
    out.add(html.sublist(pos, end));
    out.add(_ascii(anchor));
    pos = end;
  }
  out.add(html.sublist(pos));
  return out.takeBytes();
}

/// Applies MOBI 6 markup conversions to decoded HTML:
/// image `recindex` attributes to `src`, `filepos` attributes to
/// anchors and `mbp:pagebreak` elements to styled divs.
String processMobi6Html(final String html, final Map<int, String> imageNames) {
  var result = html;

  // Images: recindex / hirecindex / lowrecindex -> src.
  result = result.replaceAllMapped(
    RegExp(
      r"""(<img[^>]*?)\s(?:lowrecindex|recindex|hirecindex)\s*=\s*["']?(\d+)["']?""",
      caseSensitive: false,
    ),
    (final match) {
      final name = imageNames[int.parse(match.group(2)!)];
      return name == null ? match.group(1)! : '${match.group(1)} src="$name"';
    },
  );

  // Internal links: filepos -> #fileposN anchor.
  result = result.replaceAllMapped(
    RegExp(r"""\sfilepos\s*=\s*["']?(\d+)["']?""", caseSensitive: false),
    (final match) => ' href="#filepos${match.group(1)}"',
  );

  // Anchor ids carried via filepos-id.
  result = result.replaceAll(' filepos-id=', ' id=');

  // Page breaks.
  result = result.replaceAll(
    RegExp(
      r'<\s*/?\s*mbp:pagebreak[^>]*>',
      caseSensitive: false,
    ),
    '<div class="mbp_pagebreak"></div>',
  );

  // Light cleanup of malformed closings seen in the wild.
  result = result.replaceAll('</</', '</');
  result = result.replaceAllMapped(
    RegExp('</([a-zA-Z]+)<'),
    (final match) => '</${match.group(1)}><',
  );
  return result;
}

/// Scans resource records of a MOBI 6 book for images and fonts.
///
/// Returns the image files, font files and a map from record index
/// (as used by `recindex` attributes) to image file name.
Mobi6Resources extractMobi6Resources({
  required final Uint8List Function(int) recordAt,
  required final int recordCount,
  required final int firstImageIndex,
  required final Set<int> processedRecords,
}) {
  final images = <BinaryFile>[];
  final fonts = <BinaryFile>[];
  final imageNames = <int, String>{};

  var start = firstImageIndex;
  if (start > recordCount || start < 0) {
    start = 0; // Some PRC files carry broken headers.
  }

  var imageIndex = 0;
  for (var i = start; i < recordCount; i++) {
    if (processedRecords.contains(i)) {
      continue;
    }
    processedRecords.add(i);
    final data = recordAt(i);
    imageIndex += 1;

    if (_hasMagicBytes(data, 'FONT')) {
      final font = decodeFontRecord(data);
      fonts.add(
        BinaryFile(
          content: font.data,
          name: 'font${_padded(imageIndex)}.${font.extension}',
          type: font.extension,
          path: 'font${_padded(imageIndex)}.${font.extension}',
        ),
      );
      continue;
    }

    if (_isKnownNonImageRecord(data)) {
      continue;
    }

    final type = sniffImageType(data);
    if (type == null) {
      continue;
    }
    final name = 'image${_padded(imageIndex)}.${type.fileExtension}';
    imageNames[imageIndex] = name;
    images.add(
      BinaryFile(
        content: data,
        name: name,
        type: type.fileExtension,
        path: name,
      ),
    );
  }

  return Mobi6Resources(images, fonts, imageNames);
}

/// Resources extracted from a MOBI 6 book.
class Mobi6Resources {
  const Mobi6Resources(this.images, this.fonts, this.imageNames);

  /// Extracted images.
  final List<BinaryFile> images;

  /// Extracted fonts.
  final List<BinaryFile> fonts;

  /// Record index to image name map.
  final Map<int, String> imageNames;
}

/// Derives a best-effort TOC for MOBI 6 books.
///
/// MOBI 6 has no structured TOC; the table of contents is an HTML
/// block of `filepos` links. The longest contiguous run of anchors is
/// taken as the TOC.
Navigation deriveMobi6Navigation(final String html, final String title) {
  final anchorPattern = RegExp(
    r"""<a[^>]+href\s*=\s*["']#filepos(\d+)["'][^>]*>(.*?)</a>""",
    dotAll: true,
  );
  final matches = anchorPattern.allMatches(html).toList();
  if (matches.isEmpty) {
    return Navigation(title: title, navPoints: <NavPoint>[]);
  }

  // Longest contiguous run: anchors separated only by whitespace and
  // simple separator tags (<br>, </p><p>, <div>...).
  var bestStart = 0;
  var bestLength = 1;
  var runStart = 0;
  for (var i = 1; i <= matches.length; i++) {
    final continues = i < matches.length &&
        _onlySeparators(
          html,
          matches[i - 1].end,
          matches[i].start,
        );
    if (continues) {
      continue;
    }
    final length = i - runStart;
    if (length > bestLength) {
      bestLength = length;
      bestStart = runStart;
    }
    runStart = i;
  }

  final points = <NavPoint>[];
  for (var i = bestStart; i < bestStart + bestLength; i++) {
    final match = matches[i];
    points.add(
      NavPoint(
        classAttribute: '',
        id: 'filepos-${match.group(1)}',
        playOrder: '${points.length + 1}',
        label: _stripTags(match.group(2) ?? '').trim(),
        content: '#filepos${match.group(1)}',
      ),
    );
  }
  return Navigation(title: title, navPoints: points);
}

bool _onlySeparators(final String html, final int from, final int to) {
  if (to - from > 80) {
    return false;
  }
  final between = html.substring(from, to)
      .replaceAll(RegExp('<(br|/p|p|/div|div)[^>]*>', caseSensitive: false), '')
      .trim();
  if (between.length > 2) {
    // Allow thin separators like '. ' or '-'.
    return false;
  }
  return true;
}

String _stripTags(final String raw) =>
    raw.replaceAll(RegExp('<[^>]*>'), '');

String _padded(final int value) => value.toString().padLeft(5, '0');

const List<String> _nonImageMagics = <String>[
  'FLIS', 'FCIS', 'SRCS', 'BOUN', 'FDST', 'DATP', 'AUDI', 'VIDE',
  'RESC', 'CMET', 'PAGE',
];

bool _isKnownNonImageRecord(final Uint8List data) {
  if (data.length < 4) {
    return false;
  }
  // The Mobipocket 'unknown' marker: e9 8e 0d 0a.
  if (data[0] == 0xE9 && data[1] == 0x8E && data[2] == 0x0D && data[3] == 0x0A) {
    return true;
  }
  for (final magic in _nonImageMagics) {
    if (_hasMagicBytes(data, magic)) {
      return true;
    }
  }
  return false;
}

bool _hasMagicBytes(final Uint8List data, final String magic) {
  if (data.length < magic.length) {
    return false;
  }
  for (var i = 0; i < magic.length; i++) {
    if (data[i] != magic.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}

List<int> _asciiPattern(final String text) =>
    text.codeUnits.map((final c) => c).toList();

Uint8List _ascii(final String text) =>
    Uint8List.fromList(text.codeUnits);

int _indexOfPattern(
  final Uint8List data,
  final List<int> pattern,
  final int from, {
  final bool caseInsensitive = false,
}) {
  if (pattern.isEmpty || data.length < pattern.length) {
    return -1;
  }
  for (var i = from; i <= data.length - pattern.length; i++) {
    var matched = true;
    for (var j = 0; j < pattern.length; j++) {
      var a = data[i + j];
      var b = pattern[j];
      if (caseInsensitive) {
        if (a >= 0x41 && a <= 0x5A) a += 0x20;
        if (b >= 0x41 && b <= 0x5A) b += 0x20;
      }
      if (a != b) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return i;
    }
  }
  return -1;
}

int _indexOfByte(final Uint8List data, final int byte, final int from) {
  for (var i = from; i < data.length; i++) {
    if (data[i] == byte) {
      return i;
    }
  }
  return -1;
}

int _lastIndexOfByte(final Uint8List data, final int byte, final int from, final int to) {
  for (var i = to - 1; i >= from; i--) {
    if (data[i] == byte) {
      return i;
    }
  }
  return -1;
}
