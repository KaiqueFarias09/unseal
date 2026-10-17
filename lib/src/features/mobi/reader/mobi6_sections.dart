import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../codec/mobi_byte_search.dart';
import '../codec/mobi_text_codec.dart';
import 'mobi_text_store.dart';

/// Byte-level open-pass scan of a MOBI 6 text stream.
///
/// The eager parse derives navigation and chapter boundaries from the
/// fully decoded HTML string. The session must not materialize that
/// string at open, so this scanner collects the same facts from the
/// decompressed byte stream as it flows through the
/// [MobiTextStore.build] pass:
///
/// * every `filepos=` reference target (the anchor insertion plan);
/// * every TOC anchor candidate — an `<a …filepos=N…>` tag through the
///   following `</a>` — with label bounds in stream coordinates;
/// * every `<mbp:pagebreak` position (the section fallback).
///
/// All pattern bytes are ASCII, so byte-level scanning decodes
/// identically for the UTF-8 and cp1252 codecs the format supports.
/// The scanner keeps one bounded working buffer: markers re-scan a
/// 32-byte overlap window and deduplicate by cursor; TOC candidates
/// track their own search cursor, which advances only when a match
/// completes or a candidate is abandoned.
final class Mobi6OpenScan {
  /// A label longer than this abandons the TOC candidate. The eager
  /// regex has no bound; a quarter megabyte of anchor text without a
  /// closing tag is pathological markup, and the bound keeps the open
  /// pass's working set finite.
  static const labelCarryCap = 256 << 10;

  /// Stream positions where a `filepos=` reference points.
  final Set<int> targets = <int>{};

  /// TOC anchor candidates as (tag start, tag end, match end) in
  /// stream coordinates. The label spans (tag end, match end − 4).
  final List<(int, int, int)> tocCandidates = <(int, int, int)>[];

  /// Stream positions of `<mbp:pagebreak` openings.
  final List<int> pagebreaks = <int>[];

  Uint8List _buffer = Uint8List(0);
  var _bufferStart = 0;

  // Marker scans report positions at or after these cursors; after
  // each chunk the cursors retreat to (end − pattern window) so
  // straddling markers are found on the next round without
  // duplication.
  var _markerUpTo = 0;
  var _pagebreakUpTo = 0;

  // TOC matcher state. [_tocSearchAt] is the stream offset where the
  // next `<a` search starts; while a candidate is open it is negative
  // and [_candidateOpen]/[_candidateTagEnd]/[_closeFrom] take over.
  var _tocSearchAt = 0;
  var _candidateOpen = -1;
  var _candidateTagEnd = -1;
  var _closeFrom = 0;

  /// Consumes one decompressed record.
  void addRecord(final Uint8List chunk) {
    final merged = Uint8List.fromList(<int>[..._buffer, ...chunk]);
    _buffer = merged;
    _process();

    // Trim: keep the earliest position any scanner still owes work
    // from. Markers re-scan a small overlap; the TOC matcher keeps
    // its search cursor (or an open candidate's close-search window,
    // with three bytes of overlap so `</a>` straddling a chunk is
    // still found).
    var keepFrom = _markerUpTo;
    if (_pagebreakUpTo < keepFrom) keepFrom = _pagebreakUpTo;
    final tocKeep = _candidateOpen == -1 ? _tocSearchAt : _closeFrom - 3;
    if (tocKeep < keepFrom) keepFrom = tocKeep;
    if (keepFrom > _bufferStart) {
      final offset = keepFrom - _bufferStart;
      if (offset >= _buffer.length) {
        _buffer = Uint8List(0);
        _bufferStart = keepFrom;
      } else {
        _buffer = Uint8List.sublistView(_buffer, offset);
        _bufferStart = keepFrom;
      }
    }
  }

  /// Finishes the scan; the stream ended, so everything still pending
  /// resolves now.
  void finish() => _process();

  void _process() {
    if (_buffer.isEmpty) return;
    final start = _bufferStart;
    final end = _bufferStart + _buffer.length;

    // filepos= markers.
    var i = _markerUpTo > start ? _markerUpTo - start : 0;
    while (true) {
      final at = _indexOfAsciiIgnoreCase(_buffer, _fileposMarker, i);
      if (at == -1) break;

      final target = _parseFileposValue(_buffer, at);
      if (target != null) targets.add(target);
      i = at + 1;
    }
    _markerUpTo = end > _markerWindow ? end - _markerWindow : start;

    // pagebreak markers.
    i = _pagebreakUpTo > start ? _pagebreakUpTo - start : 0;
    while (true) {
      final at = _indexOfAsciiIgnoreCase(_buffer, _pagebreakMarker, i);
      if (at == -1) break;

      pagebreaks.add(start + at);
      i = at + 1;
    }
    _pagebreakUpTo = end > _pagebreakWindow ? end - _pagebreakWindow : start;

    // TOC candidates.
    while (true) {
      if (_candidateOpen == -1) {
        var search = _tocSearchAt > start ? _tocSearchAt - start : 0;
        var open = -1;
        while (true) {
          open = _indexOfAnchorOpen(_buffer, search);
          if (open == -1) break;

          final gt = indexOfByte(_buffer, 0x3E, open + 2);
          if (gt == -1) {
            // The tag has not closed yet; keep from its `<a` and wait.
            _tocSearchAt = start + open;
            break;
          }

          if (_tagHasFileposAttr(_buffer, open, gt)) {
            _candidateOpen = start + open;
            _candidateTagEnd = start + gt;
            _closeFrom = start + gt + 1;
            break;
          }

          search = open + 1;
        }
        if (_candidateOpen == -1) {
          if (open != -1) {
            // Waiting for the tag to close; nothing more this round.
            return;
          }
          _tocSearchAt = end;
          return;
        }
      }

      // Awaiting the label and `</a>`.
      final search = _closeFrom - 3 > start ? _closeFrom - 3 - start : 0;
      final close = _indexOfAscii(_buffer, _closeAnchor, search);
      if (close == -1) {
        if (_candidateTagEnd - start < _buffer.length && end - _candidateTagEnd > labelCarryCap) {
          // Bound exceeded: abandon like a non-match and resume the
          // tag scan after the opening.
          _tocSearchAt = _candidateOpen + 1;
          _candidateOpen = -1;
          _candidateTagEnd = -1;
          continue;
        }
        _closeFrom = end;

        return;
      }

      tocCandidates.add((_candidateOpen, _candidateTagEnd, start + close + 4));
      _tocSearchAt = start + close + 4;
      _candidateOpen = -1;
      _candidateTagEnd = -1;
    }
  }

  static final List<int> _fileposMarker = _asciiList('filepos=');
  static final List<int> _pagebreakMarker = _asciiList('<mbp:pagebreak');
  static final List<int> _closeAnchor = _asciiList('</a>');

  static final int _markerWindow = _fileposMarker.length + 24;
  static final int _pagebreakWindow = _pagebreakMarker.length;
}

/// One planned MOBI 6 session section: a raw stream span plus its
/// output name, mirroring the eager `MobiBook.chapters` tiling.
final class Mobi6Section {
  /// Creates a section over the raw span [start, end).
  const Mobi6Section(this.name, this.start, this.end);

  /// The output file name (`chapterNNNNN.html`, like the eager split).
  final String name;

  /// Inclusive raw stream start.
  final int start;

  /// Exclusive raw stream end.
  final int end;
}

/// Derives the MOBI 6 navigation from the open-pass scan, replicating
/// the eager `deriveMobi6Navigation` decision on byte-collected
/// candidates: the longest run of anchors separated only by whitespace
/// and simple separator tags becomes the table of contents.
Navigation deriveMobi6NavigationBytes(
  final Mobi6OpenScan scan,
  final MobiTextStore store,
  final String title,
  final String codec,
) {
  final candidates = scan.tocCandidates;
  if (candidates.isEmpty) return Navigation(title: title, navPoints: const <NavPoint>[]);

  var bestStart = 0;
  var bestLength = 1;
  var runStart = 0;
  for (var i = 1; i <= candidates.length; i++) {
    final continues =
        i < candidates.length && _onlySeparators(store, candidates[i - 1].$3, candidates[i].$1);
    if (continues) continue;

    final length = i - runStart;
    if (length > bestLength) {
      bestLength = length;
      bestStart = runStart;
    }
    runStart = i;
  }

  final points = <NavPoint>[];
  for (var i = bestStart; i < bestStart + bestLength; i++) {
    final (tagStart, tagEnd, matchEnd) = candidates[i];
    final label = _stripTags(decodeBytes(store.slice(tagEnd, matchEnd - 4), codec)).trim();
    final target = _targetFromTagBytes(store, tagStart, tagEnd);
    if (target == null) continue;

    points.add(
      NavPoint(
        classAttribute: '',
        id: 'filepos-$target',
        playOrder: '${points.length + 1}',
        label: label,
        content: '#filepos$target',
      ),
    );
  }

  return Navigation(title: title, navPoints: points);
}

/// The MOBI 6 section plan: the section table plus the anchor
/// insertion chain. Sections splice their own chain entries at
/// materialization time, which reproduces the eager
/// `addFileposAnchors` output exactly — including anchors the global
/// chain skipped.
final class Mobi6SectionPlan {
  /// Creates a plan from its sections and insertions.
  const Mobi6SectionPlan({required this.sections, required this.insertions});

  /// The ordered sections over the raw stream.
  final List<Mobi6Section> sections;

  /// The global anchor insertion chain: (raw offset, anchor text) in
  /// insertion order.
  final List<(int, String)> insertions;
}

/// Computes the MOBI 6 section table from the navigation targets,
/// replicating the eager `addFileposAnchors` insertion chain: anchors
/// insert in sorted target order, skipping anchors whose insertion
/// point did not advance, and the navigation anchors' insertion points
/// become the section boundaries (raw stream coordinates). Section
/// sources tile the eager processed markup: each section's slice
/// processes identically to the eager whole-document processing, so
/// canonical text concatenates to the eager text.
Mobi6SectionPlan computeMobi6Sections(
  final Mobi6OpenScan scan,
  final MobiTextStore store,
  final Navigation navigation,
) {
  final sortedTargets = scan.targets.toList()..sort();

  var chainPos = 0;
  final insertionStarts = <int, int>{};
  final insertions = <(int, String)>[];
  for (final target in sortedTargets) {
    if (target == 0 || target >= store.streamLength) continue;

    var end = target;
    final lt = _indexOfByteBounded(store, 0x3C, end);
    final gt = _indexOfByteBounded(store, 0x3E, end);
    var anchorEnd = end;
    var insertion = end;
    var anchorText = '<a id="filepos$target"></a>';
    if (gt > -1 && (gt < lt || lt == end || lt == -1)) {
      final p = _lastIndexOfByteBounded(store, 0x3C, 0, end + 1);
      final isEndTag = p > -1 && store.slice(p + 1, p + 2)[0] == 0x2F;
      final selfClosed = p > -1 && gt > p && store.slice(gt - 1, gt)[0] == 0x2F;
      if (chainPos < end && p > -1 && !isEndTag && !selfClosed) {
        // Attribute mode: the anchor text inserts before the tag's
        // `>`; the section boundary sits at the insertion start.
        anchorEnd = gt;
        insertion = gt;
        anchorText = ' filepos-id="filepos$target"';
      } else {
        anchorEnd = gt + 1;
        insertion = anchorEnd;
      }
      end = gt;
    }
    if (anchorEnd <= chainPos) continue;

    insertionStarts[target] = insertion;
    insertions.add((insertion, anchorText));
    chainPos = anchorEnd;
  }

  final boundaries = <int>[];
  for (final point in navigation.navPoints) {
    final number = RegExp(r'#filepos(\d+)$').firstMatch(point.content);
    if (number == null) continue;

    final insertion = insertionStarts[int.parse(number.group(1)!)];
    if (insertion == null) continue;
    if (boundaries.isEmpty || boundaries.last != insertion) boundaries.add(insertion);
  }
  var frontMatterEnd = 0;
  if (boundaries.isEmpty) {
    // No usable navigation anchors: fall back to pagebreak boundaries,
    // the declared session-only refinement for books without a TOC.
    if (scan.pagebreaks.length > 1) {
      boundaries.addAll(scan.pagebreaks);
    } else {
      boundaries.add(0);
    }
  } else if (boundaries.first > 0) {
    frontMatterEnd = boundaries.first;
    if (!_hasVisibleContent(store, 0, frontMatterEnd)) frontMatterEnd = 0;
  }

  final sections = <Mobi6Section>[];
  var previous = 0;
  if (frontMatterEnd > 0) {
    sections.add(Mobi6Section(_sectionName(sections.length), 0, frontMatterEnd));
    previous = frontMatterEnd;
  }
  for (final boundary in boundaries) {
    if (boundary <= previous && previous > 0) continue;
    if (boundary > store.streamLength) break;
    final from = previous;
    if (boundary > from) {
      sections.add(Mobi6Section(_sectionName(sections.length), from, boundary));
      previous = boundary;
    }
  }
  if (previous < store.streamLength) {
    sections.add(Mobi6Section(_sectionName(sections.length), previous, store.streamLength));
  }
  if (sections.isEmpty) {
    sections.add(Mobi6Section(_sectionName(0), 0, store.streamLength));
  }

  return Mobi6SectionPlan(sections: sections, insertions: insertions);
}

String _sectionName(final int index) => 'chapter${(index + 1).toString().padLeft(5, '0')}.html';

bool _hasVisibleContent(final MobiTextStore store, final int start, final int end) {
  // Bounded like the eager tag-strip check; oversized spans count as
  // visible (a multi-megabyte tag-only prefix is pathological).
  if (end - start > _visibleCheckCap) return true;

  final html = decodeBytes(store.slice(start, end), 'utf-8');

  return html.replaceAll(_anyTagPattern, '').trim().isNotEmpty;
}

const _visibleCheckCap = 2 << 20;

final RegExp _anyTagPattern = RegExp('<[^>]*>');
final RegExp _separatorTagsPattern = RegExp('<(br|/p|p|/div|div)[^>]*>', caseSensitive: false);

bool _onlySeparators(final MobiTextStore store, final int from, final int to) {
  if (to < from) return false;
  if (to - from > _separatorCheckByteCap) return false;

  final gap = decodeBytes(store.slice(from, to), 'utf-8');
  if (gap.length > 80) return false;

  return gap.replaceAll(_separatorTagsPattern, '').trim().length <= 2;
}

/// Four bytes per code unit is UTF-8's worst case, so a longer gap
/// cannot pass the eager `> 80` string-length check.
const _separatorCheckByteCap = 4 * 80;

String _stripTags(final String raw) => raw.replaceAll(_anyTagPattern, '');

int? _targetFromTagBytes(final MobiTextStore store, final int tagStart, final int tagEnd) {
  final head = store.slice(tagStart, tagEnd);
  final markerAt = _indexOfAsciiIgnoreCase(head, _asciiList('filepos='), 0);
  if (markerAt == -1) return null;

  return _parseFileposValue(head, markerAt);
}

// ---------------------------------------------------------------------------
// Byte pattern helpers (ASCII-exact for the supported codecs)
// ---------------------------------------------------------------------------

List<int> _asciiList(final String text) => text.codeUnits;

final List<int> _attrName = _asciiList('filepos');

int _indexOfAscii(final Uint8List data, final List<int> pattern, final int from) {
  if (pattern.isEmpty || data.length < pattern.length) return -1;

  outer:
  for (var i = from; i <= data.length - pattern.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }

    return i;
  }

  return -1;
}

int _indexOfAsciiIgnoreCase(final Uint8List data, final List<int> pattern, final int from) {
  if (pattern.isEmpty || data.length < pattern.length) return -1;

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

/// Parses the decimal target after a `filepos=` marker at [at],
/// including the optional quote, mirroring the eager anchor scanner.
int? _parseFileposValue(final Uint8List data, final int at) {
  const markerLength = 8;
  var i = at + markerLength;
  if (i < data.length && (data[i] == 0x27 || data[i] == 0x22)) i++;
  var value = 0;
  var digits = 0;
  while (i < data.length && data[i] >= 0x30 && data[i] <= 0x39) {
    value = value * 10 + (data[i] - 0x30);
    i++;
    digits++;
  }

  return digits > 0 ? value : null;
}

bool _tagHasFileposAttr(final Uint8List buffer, final int open, final int gt) {
  var i = open + 2;
  while (true) {
    final at = _indexOfAsciiIgnoreCase(buffer, _attrName, i);
    if (at == -1 || at >= gt) return false;
    // The attribute needs a markup-space boundary before the name,
    // like the eager `\sfilepos=` pattern.
    if (at > open + 2 && _isMarkupSpace(buffer[at - 1])) return true;

    i = at + 1;
  }
}

bool _isMarkupSpace(final int byte) {
  return byte == 0x20 || (byte >= 0x09 && byte <= 0x0D);
}

int _indexOfAnchorOpen(final Uint8List data, final int from) {
  for (var i = from; i + 2 < data.length; i++) {
    if (data[i] == 0x3C && data[i + 1] == 0x61 && data[i + 2] != 0x3E) return i;
  }

  return -1;
}

/// Forward byte search against the store with a bounded window; the
/// eager insertion walk searches the whole stream, so this only
/// diverges on markup without the searched byte for over 64 KiB.
int _indexOfByteBounded(final MobiTextStore store, final int byte, final int from) {
  const window = 64 << 10;
  var start = from;
  while (start < store.streamLength) {
    final end = start + window > store.streamLength ? store.streamLength : start + window;
    final at = indexOfByte(store.slice(start, end), byte, 0);
    if (at != -1) return start + at;
    if (end == store.streamLength) return -1;
    start = end;
  }

  return -1;
}

int _lastIndexOfByteBounded(
  final MobiTextStore store,
  final int byte,
  final int from,
  final int to,
) {
  const window = 64 << 10;
  var end = to;
  while (end > from) {
    final start = end - window < from ? from : end - window;
    final slice = store.slice(start, end);
    final at = lastIndexOfByte(slice, byte, 0, slice.length);
    if (at != -1) return start + at;
    if (start == from) return -1;
    end = start;
  }

  return -1;
}
